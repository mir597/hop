;*=====================================================================*/
;*    serrano/prgm/project/hop/3.0.x/scheme2js/scope.scm               */
;*    -------------------------------------------------------------    */
;*    Author      :  Florian Loitsch                                   */
;*    Creation    :  2007-13                                           */
;*    Last change :  Fri Aug 14 06:38:12 2015 (serrano)                */
;*    Copyright   :  2013-15 Manuel Serrano                            */
;*    -------------------------------------------------------------    */
;*    JavaScript scopes                                                */
;*=====================================================================*/

;*---------------------------------------------------------------------*/
;*    The module                                                       */
;*---------------------------------------------------------------------*/
(module scope
   
   (import config
	   tools
	   nodes
	   dump-node
	   export-desc
	   walk
	   verbose
	   free-vars
	   captured-vars)
   
   (static (wide-class Call/cc-Let::Let)
	   
	   (wide-class Scope-Call/cc-Lambda::Lambda)
	   
	   (wide-class Call/cc-Tail-rec::Tail-rec
	      contains-call/cc?::bool
	      modified-vars::pair-nil)
	   
	   (wide-class Scope-Var::Var
	      (inside-loop?::bool (default #f))
	      (call/cc-when-alive?::bool (default #f))
	      (modified-after-call/cc?::bool (default #f))
	      (modified-outside-local?::bool (default #f))
	      (repl-var (default #f)))
	      
	   (class Main-Env
	      suspend/resume?::bool))
   
   (export (scope-resolution! tree::Module)
	   (scope-flattening! tree::Module)))

;; Note that call/cc calls may return different values at each call. The
;; letrec-expansion pass however ensures, that call/cc-calls can not happen
;; inside a Letrec-form. Handling call/cc-calls inside Lets is not that
;; difficult, though: the let-frame is constructed only
;; after the call and the variable's value stays constant during its lifetime.
;;
;; Once some Scopes have been removed we need to look at function-vars. If
;; suspend/resume (which is implied by call/cc) is activated, then some
;; variables need to be boxed.
;; Function variables that escape and are not constant (independent of
;; init-var), and which have Call/cc-call in their Scope, need to be boxed.
;; If a frame (outside the concerned Scope) is already constructed for
;; some variable, they can simply add themselves into this frame.
;;
;; If a loop is initiated by a call/cc then not all Scopes need to allocate a
;; storage-object. Only if the Scope's variable escapes and there is a call/cc
;; inside the Scope, then a Storage-object is needed. Otherwise the
;; exception-based iteration already creates a new frame.

;*---------------------------------------------------------------------*/
;*    scope-resolution! ...                                            */
;*---------------------------------------------------------------------*/
(define (scope-resolution! tree::Module)
   (verbose "Scope resolution")
   (let-split! tree)
   (captured-vars tree)
   ;; no other analysis is allowed from now on, as other analyses might widen
   ;; variables, too.
   (scope-widen-vars! tree)
   (scope-predicates tree)
   (scope-temporaries! tree)
   (scope-shrink-vars! tree)
   (let-merge! tree)
   (scope-frame-alloc! tree))

;*---------------------------------------------------------------------*/
;*    let-split! ...                                                   */
;*    -------------------------------------------------------------    */
;*    split lets so they became nested lets (thereby forcing an        */
;*    order of evaluation).                                            */
;*    Most let's are going to be merged later again.                   */
;*    Difficulty: we haven't paid attention to the order of            */
;*    scope-vars and bindings (they might not even be of same number)  */
;*---------------------------------------------------------------------*/
(define (let-split! tree)
   (verbose " let-split")
   (split! tree #f))

(define-nmethod (Node.split!)
   (default-walk! this))

(define-nmethod (Let.split!)
   (with-access::Let this (kind bindings body scope-vars)
      (if (eq? kind 'letrec)
	  (default-walk! this)
	  (let ((len-bindings (length bindings))
		(len-scope-vars (length scope-vars)))
	     (cond
		((and (=fx len-bindings 1)
		      (=fx len-scope-vars 1))
		 (default-walk! this))
		((and (>fx len-bindings 0)
		      (=fx len-scope-vars 0))
		 ;; no need to keep the let.
		 (walk! (instantiate::Begin
			   (exprs (append! bindings (list body))))))
		((and (=fx len-bindings 0)
		      (>= len-scope-vars 0))
		 (default-walk! this))
		((and (=fx len-bindings 0)
		      (=fx len-scope-vars 0))
		 (walk! body))
		(else
		 ;; more than one scope-var
		 ;; more than one binding.
		 ;; each scope-var might only appear in one binding.
		 ;; (otherwise it would not be a 'let'.
		 ;; search the first binding for a scope-var
		 ;; if none is found -> begin
		 ;; otherwise split the binding with the corresponding var.
		 (let* ((binding (car bindings))
			(binding-var (search-binding-var binding scope-vars)))
		    (set! bindings (cdr bindings))
		    (if binding-var
			(begin
			   (set! scope-vars
				 (filter! (lambda (var)
					     (not (eq? var binding-var)))
					  scope-vars))
			   (walk! (instantiate::Let
				     (location (with-access::Node this (location) location))
				     (scope-vars (list binding-var))
				     (bindings (list binding))
				     (body this)
				     (kind 'let))))
			(walk! (instantiate::Begin
				  (exprs (list binding this))))))))))))

(define (search-binding-var tree vars)
   (bind-exit (found-fun)
      (search tree #f vars found-fun)
      #f))

(define-nmethod (Node.search vars found-fun)
   (default-walk this vars found-fun))

(define-nmethod (Lambda.search vars found-fun)
   ;; don't go into lambdas
   'done)

(define-nmethod (Ref.search vars found-fun)
   (with-access::Ref this (var)
      (let ((varL (memq var vars)))
	 (if varL
	     (found-fun (car varL))
	     #f))))

;; some predicates (which are added as .flags to the vars):
;;  auxiliary predicates:
;;   - constant?, escapes?, captured? (by free-vars and captured-vars)
;;
;;   - inside-loop?: variable is declared inside while-loop.
;;   - call/cc-when-alive? : a call/cc is inside the scope
;;   - modified-after-call/cc? : the variable is updated after a call/cc-call.
;;
;;  main predicates:
;;   - needs-boxing? : the variable is not constant, escapes, and has a call/cc
;;         call inside the scope. Due to the call/cc it must 
;;         be boxed to ensure that the function that uses the escaping variable
;;         still references the same var after restoration. (The boxing can
;;         occur anywhere before its use).
;;   - needs-uniquization? : the variable is "constant", captured, and is
;;         inside a loop. The init-value may change depending on the
;;         iteration. Each capturing function must capture a "uniquized"
;;         variable.
;;   - needs-frame? : the variable is not constant, inside a loop, and is
;;         captured. Each capturing function needs to capture a separate
;;         frame. The frame must be constructed at each iteration.
;;   - needs-update? : the variable is not constant, has a call/cc, and is
;;         modified after a call/cc. The call/ccs that have captured the
;;         variable need to be updated during a finally.
;;   (- indirect? : if a variable is only referenced through a storage-object.)

(define (scope-predicates tree)
   (verbose " predicates")
   (auxiliary-predicates tree)
   (main-predicates tree))

(define (auxiliary-predicates tree)
   (verbose " auxiliary predicates")
   (scope-inside-loop? tree)
   (scope-call/cc tree))

;*---------------------------------------------------------------------*/
;*    scope-widen-vars! ...                                            */
;*---------------------------------------------------------------------*/
(define (scope-widen-vars! tree)
   (verbose " Widening vars")
   (widen!_ tree #f))

;*---------------------------------------------------------------------*/
;*    widen!-vars ...                                                  */
;*---------------------------------------------------------------------*/
(define (widen!-vars vs)
   (for-each (lambda (v)
		(widen!::Scope-Var v))
      vs))

;*---------------------------------------------------------------------*/
;*    widen!_ ::Node ...                                               */
;*---------------------------------------------------------------------*/
(define-nmethod (Node.widen!_)
   (default-walk this))

;*---------------------------------------------------------------------*/
;*    widen!_ ::Module ...                                             */
;*---------------------------------------------------------------------*/
(define-nmethod (Module.widen!_)
   (with-access::Module this (scope-vars runtime-vars imported-vars this-var)
      (widen!-vars scope-vars)
      (widen!-vars runtime-vars)
      (widen!-vars imported-vars)
      (widen!::Scope-Var this-var))
   (default-walk this))

;*---------------------------------------------------------------------*/
;*    widen!_ ::Lambda ...                                             */
;*---------------------------------------------------------------------*/
(define-nmethod (Lambda.widen!_)
   (with-access::Lambda this (scope-vars this-var)
      (widen!-vars scope-vars)
      (widen!::Scope-Var this-var))
   (default-walk this))

;*---------------------------------------------------------------------*/
;*    widen!_ ::Scope ...                                              */
;*---------------------------------------------------------------------*/
(define-nmethod (Scope.widen!_)
   (with-access::Scope this (scope-vars)
      (widen!-vars scope-vars))
   (default-walk this))

;*---------------------------------------------------------------------*/
;*    widen!_ ::Ref ...                                                */
;*---------------------------------------------------------------------*/
(define-nmethod (Ref.widen!_)
   (with-access::Ref this (var)
      (unless (isa? var Scope-Var)
	 (error "scope" "Internal Error: not scope-var: " (node->list this)))))


;*---------------------------------------------------------------------*/
;*    scope-inside-loop? ...                                           */
;*    -------------------------------------------------------------    */
;*    adds inside-loop?-flag.                                          */
;*---------------------------------------------------------------------*/
(define (scope-inside-loop? tree)
   (verbose "  inside loop?")
   (inside tree #f #f))

;*---------------------------------------------------------------------*/
;*    inside ::Node ...                                                */
;*---------------------------------------------------------------------*/
(define-nmethod (Node.inside inside-loop?::bool)
   (default-walk this inside-loop?))

;*---------------------------------------------------------------------*/
;*    inside ::Execution-Unit ...                                      */
;*---------------------------------------------------------------------*/
(define-nmethod (Execution-Unit.inside inside-loop?)
   ;; by default all variables.inside-loop? are set to #f. no need to do
   ;; anything here.
   ;; clear inside-loop?-flag for contained nodes.
   (default-walk this #f))

;*---------------------------------------------------------------------*/
;*    inside ::Scope ...                                               */
;*---------------------------------------------------------------------*/
(define-nmethod (Scope.inside loop?)
   (with-access::Scope this (scope-vars)
      (for-each (lambda (var)
		   (with-access::Scope-Var var (inside-loop?)
		      (set! inside-loop? loop?)))
		scope-vars))
   (default-walk this loop?))

;*---------------------------------------------------------------------*/
;*    inside ::Lambda ...                                              */
;*---------------------------------------------------------------------*/
(define-nmethod (Lambda.inside loop?)
   (with-access::Lambda this (isloop? body)
      (default-walk body isloop?)))
      
;*---------------------------------------------------------------------*/
;*    inside ::Tail-rec ...                                            */
;*---------------------------------------------------------------------*/
(define-nmethod (Tail-rec.inside inside-loop?)
   (with-access::Tail-rec this (scope-vars inits body)
      (for-each (lambda (var)
		   (with-access::Scope-Var var (inside-loop?)
		      (set! inside-loop? #t)))
		scope-vars)
      ;; inits are outside of loop.
      (for-each (lambda (init)
		   (walk init inside-loop?))
		inits)
      (walk body #t)))

;; determine if a let contains a call/cc. Every variable of the let is
;; flagged by .call/cc-when-alive? if it has.
;; also: for any variable inside a let determine if it is modified after a
;; call/cc. If it is modified, then the var is flagged with
;; .modified-after-call/cc? If the modification is inside a loop, then the
;; location of the mutation might before the actual call/cc-call.
;; Ex:
;;    (let ((x ..))
;;       (let loop ()
;;          (set! x ..)
;;          (call/cc ...))
;;          (loop)
;; Due to the loop, a 'set!' happens after the call/cc, even though the
;; set!-line is before the call/cc-line.
;;   
;; Global variables are excluded (the are simply not affected by call/ccs).
(define (scope-call/cc tree)
   (when (config 'suspend/resume)
      (verbose " Looking for call/ccs inside scopes")
      (call/ccs tree #f '() (make-eq-hashtable))))

;; the 'surrounding-scopes' and 'var->scope-ht' are here just to shield 'let's
;; from 'while's.
;; for instance:
;;  in the following example 'x' is inside a while, but _not_ modified after a
;;  call/cc. The 'let' is completely contained within the 'while'.
;;
;;         (while  (let ((x (some-fun))) (set! x ...) ... (call/cc)))
;;
;;
;;  in the following example 'x' is inside a while, and modified after a
;;  call/cc (even though it is located before the call/cc-call). The while is
;;  nested inside the let.
;;
;;         (let ((x y)) (while .. (set! x ...) ... (call/cc)))
;;   
(define-nmethod (Node.call/ccs surrounding-scopes var->scope-ht)
   (default-walk this surrounding-scopes var->scope-ht))

(define-nmethod (Lambda.call/ccs surrounding-scopes var->scope-ht)
   (with-access::Lambda this (scope-vars)
      (let ((ht (make-eq-hashtable)))
	 (for-each (lambda (var)
		      (hashtable-put! ht var this))
		   scope-vars)
	 (default-walk this (list this) ht)
	 (when (isa? this Scope-Call/cc-Lambda)
	    (for-each (lambda (var)
			 (with-access::Scope-Var var (call/cc-when-alive?)
			    (set! call/cc-when-alive? #t)))
		      scope-vars)
	    (shrink! this)))))

(define-nmethod (Let.call/ccs surrounding-scopes var->scope-ht)
   (with-access::Let this (kind scope-vars bindings body)
      (let ((this+surrounding-scopes (cons this surrounding-scopes)))
	 ;; in theory lets and letrecs should be identical for this pass (due
	 ;; to the letrec-expansion). The if here should hence not be
	 ;; necessary.
	 (if (eq? kind 'letrec)
	     (begin
		;; letrec -> add variables before traversing bindings
		(for-each (lambda (var)
			     (hashtable-put! var->scope-ht var this))
			  scope-vars)
		(for-each (lambda (binding)
			     (walk binding this+surrounding-scopes
				   var->scope-ht))
			  bindings))
	     (begin
		;; we do not yet add the variables into the
		;; hashtable. The refs to the Let-variables are hence
		;; 'unresolved'. The Set! has to be aware of that.
		;; The main advantage is, that the Set! can be faster.
		(for-each (lambda (binding)
			     (walk binding surrounding-scopes
				   var->scope-ht))
			  bindings)
		(for-each (lambda (var)
			     (hashtable-put! var->scope-ht var this))
			  scope-vars)))
	 (walk body this+surrounding-scopes var->scope-ht)
	 (when (isa? this Call/cc-Let)
	    (for-each (lambda (var)
			 (with-access::Scope-Var var (call/cc-when-alive?)
			    (set! call/cc-when-alive? #t)))
		      scope-vars)
	    (shrink! this))
	 (for-each (lambda (var)
		      (hashtable-remove! var->scope-ht var))
		   scope-vars))))

(define-nmethod (Tail-rec.call/ccs surrounding-scopes var->scope-ht)
   (with-access::Tail-rec this (scope-vars inits body)
      ;; the loop-variables are treated similary to Let-variables. the
      ;; variables are added to the ht only after the inits have been
      ;; traversed. Any call/cc during initialisation is hence part of the
      ;; surrounding scope, and not the loop.
      ;;
      ;; sidenote: from now on the order of inits is fixed.
      (for-each (lambda (init)
		   (walk init surrounding-scopes var->scope-ht))
		inits)
      (for-each (lambda (var)
		   (hashtable-put! var->scope-ht var this))
		scope-vars)
      (widen!::Call/cc-Tail-rec this
	 (contains-call/cc? #f)
	 (modified-vars '()))
      (walk body (cons this surrounding-scopes) var->scope-ht)
      (with-access::Call/cc-Tail-rec this (contains-call/cc? modified-vars)
	 (when contains-call/cc?
	    (for-each (lambda (var)
			 (with-access::Scope-Var var (call/cc-when-alive?)
			    (set! call/cc-when-alive? #t)))
		      scope-vars)
	    (for-each (lambda (var)
			 (with-access::Scope-Var var (modified-after-call/cc?)
			    (set! modified-after-call/cc? #t)))
		      modified-vars)
	    (shrink! this)))
      (for-each (lambda (var)
		   (hashtable-remove! var->scope-ht var))
		scope-vars)))

(define-nmethod (Call.call/ccs surrounding-scopes var->scope-ht)
   (default-walk this surrounding-scopes var->scope-ht)
   (when (with-access::Call this (call/cc?) call/cc?)
      (for-each (lambda (scope)
		   (cond
		      ((isa? scope Lambda) (widen!::Scope-Call/cc-Lambda scope))
		      ((isa? scope Let) (widen!::Call/cc-Let scope))
		      ((isa? scope Call/cc-Tail-rec)
		       (with-access::Call/cc-Tail-rec scope (contains-call/cc?)
			  (set! contains-call/cc? #t)))))
		surrounding-scopes)))

(define-nmethod (Set!.call/ccs surrounding-scopes var->scope-ht)
   (default-walk this surrounding-scopes var->scope-ht)
   (with-access::Set! this (lvalue val)
      (with-access::Ref lvalue (var)
	 (with-access::Scope-Var var (modified-after-call/cc?)
	    (when (not modified-after-call/cc?)
	       (let ((scope (hashtable-get var->scope-ht var)))
		  (cond
		     ((not scope)
		      ;; the var is just now bound for the first time (i.e. we
		      ;; are in the bindings-part of a 'let').
		      ;; -> the variable can not be '.modified-after-call/cc?'.
		      'do-nothing)
		     ((or (isa? scope Scope-Call/cc-Lambda)
			  (isa? scope Call/cc-Let))
		      ;; there was already a call/cc in the scope of the var
		      (set! modified-after-call/cc? #t))
		     ((isa? scope Call/cc-Tail-rec)
		      (with-access::Call/cc-Tail-rec scope (contains-call/cc?
							    modified-vars)
			 (if contains-call/cc?
			     (set! modified-after-call/cc? #t)
			     ;; otherwise let's see if we are inside a while,
			     ;; and register us, in case the loop has a call/cc
			     ;; later on.
			     (cons-set! modified-vars var))))
		     (else
		      ;; find outer-most while inside the scope
		      (let loop ((scopes surrounding-scopes)
				 (last-loop #f))
			 (cond
			    ((or (null? scopes)
				 (eq? scope (car scopes)))
			     (if last-loop
				 (with-access::Call/cc-Tail-rec last-loop
				       (modified-vars)
				    (cons-set! modified-vars var))))
			    ((isa? (car scopes) Call/cc-Tail-rec)
			     (loop (cdr scopes) (car scopes)))
			    (else
			     (loop (cdr scopes) last-loop))))))))))))


;*---------------------------------------------------------------------*/
;*    main-predicates ...                                              */
;*    -------------------------------------------------------------    */
;*    assigns the predicates for each variable                         */
;*---------------------------------------------------------------------*/
(define (main-predicates tree)
   (main tree (instantiate::Main-Env
		 (suspend/resume? (config 'suspend/resume)))))

;*---------------------------------------------------------------------*/
;*    boxed? ...                                                       */
;*---------------------------------------------------------------------*/
(define (boxed? var)
   ;; TODO: only true, when using 'with' or boxes. not when using anonymous
   ;; functions!
   (with-access::Scope-Var var (needs-boxing? needs-frame? needs-uniquization?)
      (or needs-boxing? needs-frame? needs-uniquization?)))

;*---------------------------------------------------------------------*/
;*    compute-predicates ...                                           */
;*---------------------------------------------------------------------*/
(define (compute-predicates var::Var suspend-resume?)
   (with-access::Scope-Var var (constant? escapes? captured? inside-loop?
					  call/cc-when-alive?
					  modified-after-call/cc?
					  mutated-outside-local?
					  needs-boxing? needs-frame?
					  needs-uniquization? needs-update?
					  value id)
;*        (tprint id                                                   */
;* 	  " constant?: " constant?                                     */
;* 	  " escapes?: " escapes?                                       */
;* 	  " captured?: " captured?                                     */
;* 	  " inside-loop?: " inside-loop?)                              */
; 	      " call/cc-when-alive?: " call/cc-when-alive?
; 	      " modified-after-call/cc?: " modified-after-call/cc?
; 	      " mutated-outside-local?: " mutated-outside-local?)

      ;; Variables that are not inside any scope, or that do not need any scope
      ;; (either cause they are not in any loop, or cause they are reused) may
      ;; need to be boxed (or put into a scope again) if they escape (and if
      ;; there is a call/cc inside their scope)
      ;; If a var needs to be boxed it is marked with .needs-boxing?
      (set! needs-boxing? (and suspend-resume?
			       (not constant?)
			       escapes?
			       (or mutated-outside-local?
				   modified-after-call/cc?)))
      (set! needs-frame? (and inside-loop?
			      captured?
			      (not constant?)))
      (set! needs-uniquization? (and inside-loop?
				     captured?
				     constant?
				     (not (isa? value Const))))
      (set! needs-update? (and (not (boxed? var))
			       modified-after-call/cc?))))

;*---------------------------------------------------------------------*/
;*    main ::Node ...                                                  */
;*---------------------------------------------------------------------*/
(define-nmethod (Node.main)
   (default-walk this))

;*---------------------------------------------------------------------*/
;*    main ::Module ...                                                */
;*---------------------------------------------------------------------*/
(define-nmethod (Module.main)
   (with-access::Main-Env env ((sr? suspend/resume?))
      (with-access::Module this (scope-vars runtime-vars imported-vars this-var)
	 (for-each (lambda (v) (compute-predicates v sr?)) scope-vars)
	 (for-each (lambda (v) (compute-predicates v sr?)) runtime-vars)
	 (for-each (lambda (v) (compute-predicates v sr?)) imported-vars)
	 (compute-predicates this-var sr?)))
   (default-walk this))

;*---------------------------------------------------------------------*/
;*    main ::Lambda ...                                                */
;*---------------------------------------------------------------------*/
(define-nmethod (Lambda.main)
   (with-access::Main-Env env ((sr? suspend/resume?))
      (with-access::Lambda this (scope-vars this-var)
	 (for-each (lambda (v) (compute-predicates v sr?)) scope-vars)
	 (compute-predicates this-var sr?)))
   (default-walk this))
   
;*---------------------------------------------------------------------*/
;*    main ::Scope ...                                                 */
;*---------------------------------------------------------------------*/
(define-nmethod (Scope.main)
   (with-access::Main-Env env ((sr? suspend/resume?))
      (with-access::Scope this (scope-vars)
	 (for-each (lambda (v) (compute-predicates v sr?)) scope-vars)))
   (default-walk this))

;; introduce temporary variables for formals and loop-variables.
;; - formals are not allowed to be boxed.
;; - loop-variables that need to be inside a frame are moved inside the loop's
;;  body, so that the loop variables are only temporary variables (that are not
;;  concerned by frame allocation anymore...).
(define (scope-temporaries! tree)
   (temporaries!_ tree #f))

(define-nmethod (Node.temporaries!_)
   (default-walk this))

(define (create-temporaries! l pred)
   (let loop ((l l)
	      (created-temp? #f))
      (cond
	 ((null? l)
	  created-temp?)
	 ((pred (car l))
	  (let ((var (car l)))
	     (with-access::Scope-Var var (repl-var)
		(set! repl-var (instantiate::Var
				  (id 'tmp)
				  (kind 'local)))
		(widen!::Scope-Var repl-var)))
	  (loop (cdr l) #t))
	 (else
	  (loop (cdr l) created-temp?)))))

(define (create-let vars body)
   (let loop ((vars vars)
	      (let-vars '())
	      (inits '()))
      (cond
	 ((null? vars)
	  (instantiate::Let
	     (scope-vars let-vars)
	     (bindings inits)
	     (body body)
	     (kind 'let)))
	 ((with-access::Scope-Var (car vars) (repl-var) repl-var)
	  (let* ((var (car vars))
		 (repl-var (with-access::Scope-Var var (repl-var) repl-var)))
	     (loop (cdr vars)
		   (cons var let-vars)
		   (cons (var-assig var (var-reference repl-var)) inits))))
	 (else
	  (loop (cdr vars) let-vars inits)))))

;; and removes the repl-var.
(define (replace-vars! l)
   (map! (lambda (var)
	    (with-access::Scope-Var var (repl-var)
	       (if repl-var
		   (let ((r-var repl-var))
		      (set! repl-var #f)
		      r-var)
		   var)))
	 l))

(define-nmethod (Lambda.temporaries!_)
   (with-access::Lambda this (formals scope-vars body)
      ;; Arguments must not be boxed. If necessary introduce a temporary
      ;; variable that takes its place.
      (if (create-temporaries! scope-vars boxed?)
	  (with-access::Return body (val)
	     (set! val (create-let scope-vars val))
	     (for-each walk formals) ;; replaces the variables.
	     (replace-vars! scope-vars) ;; removes repl-vars
	     (walk body)) ;; should not replace anything.
	  (default-walk this))))

(define-nmethod (Tail-rec.temporaries!_)
   (with-access::Tail-rec this (scope-vars inits body)
      (if (create-temporaries! scope-vars
			       (lambda (var)
				  (with-access::Scope-Var var (needs-frame?
							       needs-boxing?
							       needs-uniquization?)
				     (or needs-frame? needs-boxing?
					 needs-uniquization?))))
	  (begin
	     (set! body (create-let scope-vars body))
	     (for-each walk inits) ;; replaces the variables
	     (replace-vars! scope-vars) ;; removes repl-vars
	     (walk body))
	  (default-walk this))))

(define-nmethod (Ref.temporaries!_)
   ;; physically modify the Ref if var has a repl-var
   (with-access::Ref this (var id)
      (with-access::Scope-Var var (repl-var)
	 (when repl-var
	    (set! var repl-var)
	    (set! id (with-access::Var repl-var (id) id))))))


(define (scope-shrink-vars! tree)
   (verbose " Shrinking vars")
   (shrink!_ tree #f))

(define (shrink!-vars vs)
   (for-each (lambda (v) (shrink! v)) vs))

(define-nmethod (Node.shrink!_)
   (default-walk this))

(define-nmethod (Module.shrink!_)
   (with-access::Module this (scope-vars runtime-vars imported-vars this-var)
      (shrink!-vars scope-vars)
      (shrink!-vars runtime-vars)
      (shrink!-vars imported-vars)
      (shrink! this-var))
   (default-walk this))

(define-nmethod (Lambda.shrink!_)
   (with-access::Lambda this (scope-vars this-var)
      (shrink!-vars scope-vars)
      (shrink! this-var))
   (default-walk this))
   
(define-nmethod (Scope.shrink!_)
   (with-access::Scope this (scope-vars)
      (shrink!-vars scope-vars))
   (default-walk this))


;*---------------------------------------------------------------------*/
;*    let-merge! ...                                                   */
;*    -------------------------------------------------------------    */
;*    merge Scopes, if there is no "offending" instruction between     */
;*    both scopes:                                                     */
;*                                                                     */
;*    (define (f)                                                      */
;*      (let (x)                                                       */
;*        (tail-rec (y)                                                */
;*          (print y)                                                  */
;*          (let (z)                                                   */
;*              .....                                                  */
;*                                                                     */
;*    We can merge 'x' with (a new let of) lambda 'f', and 'z' with    */
;*    the tail-rec. But we can't move 'z' to lambda 'f'. (at least     */
;*    not yet).                                                        */
;*                                                                     */
;*    ->                                                               */
;*    (define (f)                                                      */
;*      [local var x]  ;; new Let                                      */
;*      (tail-rec (y z)                                                */
;*        (print y)                                                    */
;*        .....                                                        */
;*---------------------------------------------------------------------*/
(define (let-merge! tree)
   (merge! tree #f #f #f #f))

;*---------------------------------------------------------------------*/
;*    make-box ...                                                     */
;*---------------------------------------------------------------------*/
(define (make-box v)
   (cons '*box* v))

;*---------------------------------------------------------------------*/
;*    box-set! ...                                                     */
;*---------------------------------------------------------------------*/
(define (box-set! b v)
   (set-cdr! b v))

;*---------------------------------------------------------------------*/
;*    unbox ...                                                        */
;*---------------------------------------------------------------------*/
(define (unbox b)
   (cdr b))

;*---------------------------------------------------------------------*/
;*    merge! ::Node ...                                                */
;*    -------------------------------------------------------------    */
;*    last-scope-valid?::box the last scope is still valid and should  */
;*    be merged.                                                       */
;*    <-call/cc-call?::box return-value. #t when a call/cc-was         */
;*    encountered.                                                     */
;*    <-call/cc-call? implies (not last-scope-valid?). But the inverse */
;*    is not true.                                                     */
;*---------------------------------------------------------------------*/
(define-nmethod (Node.merge! last-scope last-scope-valid? <-call/cc-call?)
   (default-walk! this last-scope last-scope-valid? <-call/cc-call?))

;*---------------------------------------------------------------------*/
;*    merge! ::Module ...                                              */
;*    -------------------------------------------------------------    */
;*    Modules are only for parameters and exported vars.               */
;*---------------------------------------------------------------------*/
(define-nmethod (Module.merge! last-scope last-scope-valid? <-call/cc-call?)
   (default-walk! this #f (make-box #f) (make-box #f)))

;*---------------------------------------------------------------------*/
;*    merge! ::Lambda ...                                              */
;*    -------------------------------------------------------------    */
;*    Lambdas are only for parameters.                                 */
;*    but we want a Let directly within the Return. In the worst       */
;*    case it will have no variables.                                  */
;*---------------------------------------------------------------------*/
(define-nmethod (Lambda.merge! last-scope last-scope-valid? <-call/cc-call?)
   ;; body must be a Return.
   (with-access::Lambda this (body)
      (with-access::Return body (val)
	 (unless (isa? val Let)
	    (set! val (instantiate::Let
			 (scope-vars '())
			 (bindings '())
			 (body val)
			 (kind 'let))))
	 ;; lambda shields
	 (default-walk! this #f (make-box #f) (make-box #f)))))

;*---------------------------------------------------------------------*/
;*    merge! ::Let ...                                                 */
;*    -------------------------------------------------------------    */
;*    if possible move variables to outer scope.                       */
;*---------------------------------------------------------------------*/
(define-nmethod (Let.merge! last-scope last-scope-valid? <-call/cc-call?)
   (with-access::Let this (bindings body scope-vars)
      (set! bindings (map! (lambda (n)
			      (walk! n last-scope last-scope-valid?
				     <-call/cc-call?))
			   bindings))
      (let ((valid? (unbox last-scope-valid?))
	    (c-call? (unbox <-call/cc-call?)))
	 
	 ;; reuse the boxes
	 (box-set! last-scope-valid? #t)
	 (box-set! <-call/cc-call? #f)
	 
	 (set! body (walk! body this last-scope-valid? <-call/cc-call?))

	 ;; don't forget to update the boxes
	 (box-set! last-scope-valid? (and valid? (unbox last-scope-valid?)))
	 (box-set! <-call/cc-call? (or c-call? (unbox <-call/cc-call?)))

	 ;; let's merge.
	 (when valid?
	    (let ((this-scope-vars scope-vars))
	       (with-access::Let last-scope (scope-vars)
		  (set! scope-vars (append! this-scope-vars scope-vars))))
	    (set! scope-vars '())))
      (cond
	 ((and (null? scope-vars) (null? bindings))
	  body)
	 ((null? scope-vars)
	  (instantiate::Begin
	     (exprs (append! bindings (list body)))))
	 (else
	  this))))

;*---------------------------------------------------------------------*/
;*    merge! ::Call ...                                                */
;*    -------------------------------------------------------------    */
;*    call/cc-calls invalidate the last scope.                         */
;*---------------------------------------------------------------------*/
(define-nmethod (Call.merge! last-scope last-scope-valid? <-call/cc-call?)
   (default-walk! this last-scope last-scope-valid? <-call/cc-call?)
   (with-access::Call this (call/cc?)
      (when call/cc?
	 (box-set! last-scope-valid? #f)
	 (box-set! <-call/cc-call? #t)))
   this)

;*---------------------------------------------------------------------*/
;*    merge! ::Tail-rec ...                                            */
;*    -------------------------------------------------------------    */
;*    loops invalidate the last scope                                  */
;*---------------------------------------------------------------------*/
(define-nmethod (Tail-rec.merge! last-scope last-scope-valid? <-call/cc-call?)
   (with-access::Tail-rec this (inits body)
      (set! inits (map! (lambda (n)
			   (walk! n last-scope last-scope-valid?
				  <-call/cc-call?))
			inits))
      ;; reuse the box
      (let ((old-valid? (unbox last-scope-valid?))
	    (old-call? (unbox <-call/cc-call?)))

	 (box-set! last-scope-valid? #f)
	 (box-set! <-call/cc-call? #f)
	 (set! body (walk! body #f last-scope-valid? <-call/cc-call?))

	 ;; update the boxes...
	 ;; here we use the <-call/cc-call?. Without it we would not know if
	 ;; the previous scope was still valid.
	 ;; Ex:
	 ;;     (let ...                   [1]
	 ;;         (while ... (call/cc .. [2]
	 ;;         (let ...               [3]
	 ;; The while in [2] contains a call/cc. However it already marks its
	 ;; outer let as invalid. Without the <-call/cc-call? it would not know
	 ;; if the let of [3] could be merged into [1] or not.
	 (box-set! last-scope-valid? (and old-valid?
					  (not (unbox <-call/cc-call?))))
	 (box-set! <-call/cc-call? (or old-call? (unbox <-call/cc-call?))))

      this))

;*---------------------------------------------------------------------*/
;*    merge! ::If ...                                                  */
;*    -------------------------------------------------------------    */
;*    just an optimization. would work without, too.                   */
;*---------------------------------------------------------------------*/
(define-nmethod (If.merge! last-scope last-scope-valid? <-call/cc-call?)
   (with-access::If this (test then else)
      (set! test (walk! test last-scope last-scope-valid? <-call/cc-call?))
      (let ((old-valid? (unbox last-scope-valid?))
	    (old-c-call? (unbox <-call/cc-call?)))
	 (set! then (walk! then last-scope last-scope-valid? <-call/cc-call?))
	 (let ((then-valid? (unbox last-scope-valid?))
	       (then-c-call? (unbox <-call/cc-call?)))
	    ;; if the last scope was valid after the test, then it is still
	    ;; valid for the else-clause, too.
	    (box-set! last-scope-valid? old-valid?)
	    (box-set! <-call/cc-call? old-c-call?)
	    (set! else (walk! else last-scope last-scope-valid?
			      <-call/cc-call?))

	    ;; update the boxes
	    (box-set! last-scope-valid? (and old-valid?
					     then-valid?
					     (unbox last-scope-valid?)))
	    (box-set! <-call/cc-call? (or old-c-call?
					  then-c-call?
					  (unbox <-call/cc-call?))))))
   this)

;*---------------------------------------------------------------------*/
;*    scope-frame-alloc! ...                                           */
;*    -------------------------------------------------------------    */
;*    Creates a Scope-Allocate for every Scope that needs it, and      */
;*    creates the necessary frame-pushes.                              */
;*                                                                     */
;*    when the storage-variable itself is reused (as is the case in    */
;*    loops) then the storage object needs to be pushed on the         */
;*    activation frame. (Either using 'with', or with an anonymous     */
;*    function.)                                                       */
;*---------------------------------------------------------------------*/
(define (scope-frame-alloc! tree)
   (verbose " create storage allocations for Lets and adding frame pushes")
   (frame-alloc! tree tree))

;*---------------------------------------------------------------------*/
;*    frame-alloc! ::Node ...                                          */
;*---------------------------------------------------------------------*/
(define-nmethod (Node.frame-alloc!)
   (default-walk! this))

;*---------------------------------------------------------------------*/
;*    frame-alloc! ::Let ...                                           */
;*---------------------------------------------------------------------*/
(define-nmethod (Let.frame-alloc!)
   (with-access::Let this (scope-vars body location bindings kind)
      (let ((frame-vars '())
	    (other-vars '()))
	 (for-each (lambda (var)
		      (with-access::Var var (needs-frame?
					       needs-boxing?
					       needs-uniquization?)
			 (if (or needs-frame?
				 needs-boxing?
				 needs-uniquization?)
			     (set! frame-vars (cons var frame-vars))
			     (set! other-vars (cons var other-vars)))))
	    scope-vars)
	 (set! frame-vars (reverse! frame-vars))
	 (set! other-vars (reverse! other-vars))
;* 	 (tprint "LET: frame-vars=" (map node->list frame-vars) "\n"   */
;* 	    "  other-vars=" (map node->list other-vars) "\n"           */
;* 	    "  scope-vars=" (map node->list scope-vars) "\n"           */
;* 	    "  bindings=" (map node->list bindings) "\n"               */
;* 	    "  body=" (node->list this)                                */
;* 	    )                                                          */
	 (cond
	    ((null? frame-vars)
	     (default-walk! this))
	    ((and (not (config 'frame-push)) (not (config 'javascript-let)))
;* 	     (tprint "GLOP: " (map node->list frame-vars))             */
	     ;; apply an anonymous function
	     (let* ((formals (map (lambda (b)
				     (with-access::Set! b (lvalue)
					lvalue))
				bindings))
		    (actuals (map (lambda (b)
				     (with-access::Set! b (val)
					val))
				bindings))
		    (storage-decl (Ref-of-new-Var 'storage))
		    (storage-var (with-access::Ref storage-decl (var) var))
		    (frame-alloc (instantiate::Frame-alloc
				    (location location)
				    (storage-var (with-access::Ref storage-decl (var) var))
				    (vars frame-vars)))
		    (body (if (pair? other-vars)
			      (instantiate::Let
				 (location location)
				 (scope-vars other-vars)
				 (bindings '())
				 (kind kind)
				 (body body))
			      body))
		    (push (instantiate::Frame-push
			     (location location)
			     (frame-alloc frame-alloc)
			     (body (default-walk! body))))
		    (fun (instantiate::Lambda
			    (location location)
			    (scope-vars scope-vars)
			    (formals formals)
			    (body (instantiate::Return
				     (location location)
				     (val push)))
			    (vaarg? #f)
			    (arity (length formals))
			    (closure? #f)))
		    (call (instantiate::Call
			     (location location)
			     (operator fun)
			     (operands actuals)))
		    (mod (duplicate::Module env
			    (body call))))
;* 		(tprint "ACTUALS=" (map node->list actuals))           */
		(captured-vars mod)
		call))
	    (else
	     ;; create storage-var
	     (let* ((storage-decl (Ref-of-new-Var 'storage))
		    (storage-var (with-access::Ref storage-decl (var) var))
		    (frame-alloc (instantiate::Frame-alloc
				    (location location)
				    (storage-var (with-access::Ref storage-decl (var) var))
				    (vars frame-vars))))
		(for-each (lambda (var)
			     (with-access::Var var (indirect?)
				(set! indirect? #t)))
		   frame-vars)
		(widen!::Scope-Var storage-var)
		
		(default-walk! this)

		(instantiate::Let
		   (location location)
		   (scope-vars (list storage-var))
		   (bindings (list (instantiate::Set!
				      (location location)
				      (lvalue storage-decl)
				      (val frame-alloc))))
		   (body (instantiate::Frame-push
			    (location location)
			    (frame-alloc frame-alloc)
			    (body this)))
		   (kind 'let))))))))

;*---------------------------------------------------------------------*/
;*    scope-flattening! ...                                            */
;*---------------------------------------------------------------------*/
(define (scope-flattening! tree)
   (verbose "scope-flattening")
   (let-removal! tree))

;*---------------------------------------------------------------------*/
;*    let-removal! ...                                                 */
;*    -------------------------------------------------------------    */
;*    Remove Let-nodes.                                                */
;*    Create a declared-vars list for each module/lambda. These nodes  */
;*    need to be declared by "var".                                    */
;*---------------------------------------------------------------------*/
(define (let-removal! tree)
   (remove! tree #f #f))

;*---------------------------------------------------------------------*/
;*    remove! ::Node ...                                               */
;*    -------------------------------------------------------------    */
;*    surrounding-fun could be a Module too!                           */
;*---------------------------------------------------------------------*/
(define-nmethod (Node.remove! surrounding-fun)
   (default-walk! this surrounding-fun))

;*---------------------------------------------------------------------*/
;*    remove! ::Module ...                                             */
;*---------------------------------------------------------------------*/
(define-nmethod (Module.remove! surrounding-fun)
   (with-access::Module this (scope-vars declared-vars)
	 (set! declared-vars scope-vars)
	 (default-walk! this this)))

;*---------------------------------------------------------------------*/
;*    remove! ::Lambda ...                                             */
;*---------------------------------------------------------------------*/
(define-nmethod (Lambda.remove! surrounding-fun)
   (with-access::Lambda this (declared-vars)
      (set! declared-vars '()) ;; don't add formals. they don't need 'var'
      (default-walk! this this)))

;*---------------------------------------------------------------------*/
;*    remove! ::Let ...                                                */
;*---------------------------------------------------------------------*/
(define-nmethod (Let.remove! surrounding-fun)
   (with-access::Let this (scope-vars bindings body kind)
      (let ((fun-vars (filter (lambda (var)
				 (with-access::Var var (indirect?)
				    (not indirect?)))
			      scope-vars)))
	 (if (isa? surrounding-fun Module)
	     (with-access::Module surrounding-fun (declared-vars)
		(set! declared-vars (append fun-vars declared-vars)))
	     (with-access::Lambda surrounding-fun (declared-vars)
		(set! declared-vars (append fun-vars declared-vars)))))
      (default-walk! this surrounding-fun)
      ;; remove Let-node
      (instantiate::Begin
	 (exprs (append! bindings (list body))))))

;*---------------------------------------------------------------------*/
;*    remove! ::While ...                                              */
;*---------------------------------------------------------------------*/
(define-nmethod (While.remove! surrounding-fun)
   (with-access::While this (scope-vars)
      (let ((fun-vars (filter (lambda (var)
				 (with-access::Var var (indirect?)
				    (not indirect?))) ;; should be all of them.
			 scope-vars)))
	 (if (isa? surrounding-fun Module)
	     (with-access::Module surrounding-fun (declared-vars)
		(set! declared-vars (append fun-vars declared-vars)))
	     (with-access::Lambda surrounding-fun (declared-vars)
		(set! declared-vars (append fun-vars declared-vars))))
	 (default-walk! this surrounding-fun)
	 this)))

