;*=====================================================================*/
;*    serrano/prgm/project/hop/3.1.x/hopc/parseargs.scm                */
;*    -------------------------------------------------------------    */
;*    Author      :  Manuel Serrano                                    */
;*    Creation    :  Fri Nov 12 13:32:52 2004                          */
;*    Last change :  Sun Jan 28 06:36:58 2018 (serrano)                */
;*    Copyright   :  2004-18 Manuel Serrano                            */
;*    -------------------------------------------------------------    */
;*    Hop command line parsing                                         */
;*=====================================================================*/

;*---------------------------------------------------------------------*/
;*    The module                                                       */
;*---------------------------------------------------------------------*/
(module hopc_parseargs

   (library hop js2scheme)
   
   (import  hopc_param
	    hopc_driver
	    hopc_libdir)
   
   (export  (parse-args ::pair-nil)))

;*---------------------------------------------------------------------*/
;*    ecmascript-support ...                                           */
;*---------------------------------------------------------------------*/
(define ecmascript-es6
   '(es6-let: es6-const: es6-arrow-function: es6-default-value:
     es6-rest-argument:))

(define ecmascript-es2017
   (append ecmascript-es6 '(es2017-async:)))
      
;*---------------------------------------------------------------------*/
;*    usage ...                                                        */
;*---------------------------------------------------------------------*/
(define (usage args-parse-usage)
   (print "Hopc v" (hop-version))
   (print "usage: hopc [options] -- [bigloo-options]")
   (args-parse-usage #f)
   (newline)
   (print "Shell Variables:")
   (print "   - HOPTRACE: hop internal trace [HOPTRACE=\"key1, key2, ...\"]")
   (print "      j2s:info, j2s:type, j2s:utype, j2s:hint, j2s:usage, j2s:key, j2s:loc")
   (print "      nodejs:compile, hopscript:cache[num] (*), hopscript:function[num] (*)")
   (print "   - HOPCFLAGS: hopc compilation flags")
   (newline)
   (print "(*) runtime shell variable value")
   (newline))

;*---------------------------------------------------------------------*/
;*    parse-args ...                                                   */
;*---------------------------------------------------------------------*/
(define (parse-args args)
   (let ((rc-file #unspecified)
	 (loadp #t)
	 (exprs '())
	 (h "localhost")
	 (p (hop-port))
	 (login #f)
	 (command-string #f))
      (bind-exit (stop)
	 (args-parse (cdr args)
	    ((("-h" "--help") (help "This message"))
	     (usage args-parse-usage)
	     (exit 0))
	    (("--version" (help "Print the version and exit"))
	     (print (hop-name)"c-" (hop-version))
	     (exit 0))
	    (("--buildtag" (help "Print the buildtag and exit"))
	     (print (hop-build-tag))
	     (exit 0))
	    (("-q" (help "Do not load an init file"))
	     (set! loadp #f))
	    (("--rc-file" ?file (help "Load alternate rc file"))
	     (set! rc-file file))
	    (("--rc-dir" ?dir (help "Set rc directory"))
	     (hop-rc-directory-set! dir))
	    (("-L" ?dir (help "Add Hop library path"))
	     (bigloo-library-path-set! (cons dir (bigloo-library-path))))
	    (("--share-dir" ?dir (help "Set hopc share directory"))
	     (hopc-share-directory-set! dir))
	    (("-v?level" (help "Increase/set verbosity level (-v0 crystal silence)"))
	     (if (string=? level "")
		 (hop-verbose-set! (+fx 1 (hop-verbose)))
		 (hop-verbose-set! (string->integer level))))
	    (("-O?level" (help "Optimization level"))
	     (cond
		((string=? level "")
		 (hopc-optim-level-set! 1))
		((string=? level "x")
		 (hopc-optim-level-set! 1000)
		 (hopc-j2s-flags-set! (cons* :optim-ccall #t (hopc-j2s-flags)))
		 (hopc-bigloo-options-set!
		    (cons* "-srfi" "cache-level2" (hopc-bigloo-options))))
		(else
		 (hopc-optim-level-set! (string->integer level))))
	     (hopc-bigloo-options-set!
		(cons (format "-O~a" (min (hopc-optim-level) 6))
		   (hopc-bigloo-options))))
	    (("-g?level" (help "Increase or set debug level"))
	     (hopc-clientc-source-map-set! #t)
	     (hopc-clientc-arity-check-set! #t)
	     (hopc-clientc-type-check-set! #t)
	     (if (string=? level "")
		 (bigloo-debug-set! (+fx 1 (bigloo-debug)))
		 (bigloo-debug-set! (string->integer level)))
	     (hopc-bigloo-options-set!
		(cons (format "-g~a" level) (hopc-bigloo-options))))
	    (("-w?level" (help "Increase or set warning level (-w0 no warning)"))
	     (if (string=? level "")
		 (bigloo-warning-set! (+fx 1 (bigloo-warning)))
		 (bigloo-warning-set! (string->integer level))))
	    (("--no-color" (help "Disable colored traces"))
	     (bigloo-trace-color-set! #f))
	    (("--eval" ?string (help "Evaluate STRING"))
	     (set! exprs (cons string exprs)))
	    (("-o" ?string (help "Name the output FILE"))
	     (hopc-destination-set! string))
	    (("-t" ?string (help "Name the temporary FILE"))
	     (hopc-temp-set! string))
	    (("-s" (help "Stop after Bigloo code generation"))
	     (hopc-pass-set! 'bigloo))
	    (("-c" (help "Stop after code object generation"))
	     (hopc-pass-set! 'object)
	     (hopc-bigloo-options-set!
		(append (hopc-bigloo-options) (list "-c"))))
	    (("-y" (help "Generate a shared library"))
	     (hopc-js-module-main-set! #f)
	     (hopc-pass-set! 'so))
	    (section "Configuration and devkit")
	    (("--safe" (help "Compile and link in safe mode"))
	     (hopc-bigloo-safe-option-set! '("-unsafe" "-safel")))
	    (("--unsafe" (help "Compile and link in safe mode"))
	     (hopc-bigloo-safe-option-set! '("-unsafe")))
	    (("--bigloo=?bigloo" (help "Set the Bigloo binary file path"))
	     (hopc-bigloo-set! bigloo))
	    (("--bigloo-lib-dir=?dir" (help "Set the Bigloo library path"))
	     (bigloo-override-config! dir)
	     (hopc-bigloo-options-set!
		(cons* "-lib-dir" dir (hopc-bigloo-options))))
	    (("--reset-bigloo-options" (help "Reset all Bigloo options"))
	     (hopc-bigloo-options-set! '()))
	    ((("-j" "--client-js") (help "Generate a client-side JavaScript file"))
	     (hopc-pass-set! 'client-js))
	    ((("-a" "--afile") ?file (help "Set access file"))
	     (hopc-access-file-set! file))
	    (("--mkheap" (help "Build a js heap file"))
	     (hopc-jsheap-set! #t))

	    (section "Code generation")
	    (("-m32" (help "Generate 32-bit code"))
	     (hopc-long-size-set! 32))
	    (("-m64" (help "Generate 64-bit code"))
	     (hopc-long-size-set! 64))
	    (("-muint32" (help "Generate uint32 variables and constants"))
	     (hopc-uint32-set! #t))
	    (("--source-map" (help "Enable source-map table generation"))
	     (hopc-clientc-source-map-set! #t))
	    (("--no-source-map" (help "Disable source-map table generation"))
	     (hopc-clientc-source-map-set! #f))
	    (("--use-strict" (help "Enable use-strict annotation"))
	     (hopc-clientc-use-strict-set! #t))
	    (("--no-use-strict" (help "Disable use-strict annotation"))
	     (hopc-clientc-use-strict-set! #f))
	    (("--arity-check" (help "Enable arity-check annotation"))
	     (hopc-clientc-arity-check-set! #t))
	    (("--no-arity-check" (help "Disable arity-check annotation"))
	     (hopc-clientc-arity-check-set! #f))
	    (("--type-check" (help "Enable type-check annotation"))
	     (hopc-clientc-type-check-set! #t))
	    (("--no-type-check" (help "Disable type-check annotation"))
	     (hopc-clientc-type-check-set! #f))
	    (("--meta" (help "Enable meta annotation"))
	     (hopc-clientc-meta-set! #t))
	    (("--no-meta" (help "Disable meta annotation"))
	     (hopc-clientc-type-check-set! #f))
	    ((("-l" "--language") ?lang (help "Set the source language (\"auto\", \"hop\", or \"hopscript\")"))
	     (unless (member lang '("hop" "hopscript"))
		(error "hopc" "Unknown language, see -help" lang))
	     (hopc-source-language-set! (string->symbol lang)))
	    
	    (section "JavaScript dialect and features")
	    (("--js-worker" (help "Enable JavaScript workers"))
	     (hopc-js-worker-set! #t))
	    (("--js-no-worker" (help "Disable JavaScript workers"))
	     (hopc-js-worker-set! #f))
	    (("--js-worker-slave" (help "Compile a worker slave code"))
	     (hopc-js-worker-slave-set! #t))
	    (("--js-no-worker-slave" (help "Compile a worker master code"))
	     (hopc-js-worker-slave-set! #f))
	    (("--js-module-name" ?name (help "Set Bigloo module name"))
	     (hopc-js-module-name-set! name))
	    (("--js-module-path" ?path (help "Set Bigloo module path"))
	     (hopc-js-module-path-set! path))
	    (("--js-module-main" (help "Force generate a main clause"))
	     (hopc-js-module-main-set! #t))
	    (("--js-no-module-main" (help "Force not generate a main clause"))
	     (hopc-js-module-main-set! #f))
	    (("--js-no-header" (help "Don't generate hopscript header"))
	     (hopc-js-header-set! #f))
	    (("--js-header" (help "Generate hopscript header"))
	     (hopc-js-header-set! #t))
	    (("--js-return-as-exit" (help "Consider top level returns as exit"))
	     (hopc-js-return-as-exit-set! #t))
	    (("--js-no-return-as-exit" (help "Consider top level returns as error"))
	     (hopc-js-return-as-exit-set! #f))
	    (("--js-type-annotations" (help "Enable type annotations"))
	     (hopc-js-type-annotations-set! #t))
	    (("--js-no-type-annotations" (help "Disable type annotations"))
	     (hopc-js-type-annotations-set! #f))
	    (("--js-driver" ?driver (help "Set j2s compiler driver"))
	     (hopc-js-driver-set! driver))
	    (("--js-show-driver" (help "Set j2s compiler driver"))
	     (print (js-driver->string))
	     (exit 0))
	    (("--js-target-es5" (help "Generate a client-side JavaScript 1.5 file"))
	     (hopc-js-target-set! 'es5)
	     (j2s-compile-options-set!
		(cons* :target 'es5 (j2s-compile-options)))
	     (hopc-pass-set! 'client-js))
	    (("--js-es6" (help "Enable all EcmaScript 6 support"))
	     (j2s-compile-options-set!
		(append
		   (apply append
		      (map (lambda (f) (list f #t)) ecmascript-es6))
		   (j2s-compile-options))))
	    (("--js-es2017" (help "Enable all EcmaScript 2017 support"))
	     (j2s-compile-options-set!
		(append
		   (apply append
		      (map (lambda (f) (list f #t)) ecmascript-es2017))
		   (j2s-compile-options))))
	    (("--js-option" ?opt ?val (help "Add JavaScript compilation option"))
	     (j2s-compile-options-set!
		(cons* (string->keyword opt)
		   (cond
		      ((or (string=? val "true") (string=? val "#t")) #t)
		      ((or (string=? val "false") (string=? val "#f")) #f)
		      ((string->number val) => (lambda (val) val))
		      (else val))
		   (j2s-compile-options))))
	    (("--no-server" (help "Hop compatibility, ignored"))
	     #unspecified)
	    (("-p" ?port (help "Hop compatibility, ignored"))
	     #unspecified)
	    (("-fccall" (help "Enable call caches (-Ox)"))
	     (hopc-j2s-flags-set! (cons* :optim-ccall #t (hopc-j2s-flags))))
	    (("-fno-ccall" (help "Disable call caches"))
	     (hopc-j2s-flags-set! (cons* :optim-ccall #f (hopc-j2s-flags))))
	    (("-fhint" (help "Enable hint typing (-Ox)"))
	     (hopc-j2s-flags-set! (cons* :optim-hint #t (hopc-j2s-flags))))
	    (("-fno-hint" (help "Disable hint typing"))
	     (hopc-j2s-flags-set! (cons* :optim-hint #f (hopc-j2s-flags))))
	    (("-fcast" (help "Enable cast optimization (-Ox)"))
	     (hopc-j2s-flags-set! (cons* :optim-cast #t (hopc-j2s-flags))))
	    (("-fno-cast" (help "Disable cast optimization"))
	     (hopc-j2s-flags-set! (cons* :optim-cast #f (hopc-j2s-flags))))
	    (("-fshared-pcache" (help "Share pcaches (-Ox)"))
	     (hopc-j2s-flags-set! (cons* :shared-pcache #t (hopc-j2s-flags))))
	    (("-fno-shared-pcache" (help "Disable share pcaches"))
	     (hopc-j2s-flags-set! (cons* :shared-pcache #f (hopc-j2s-flags))))
	    (("-fthis" (help "Enable fast this access"))
	     (hopc-j2s-flags-set! (cons* :optim-this #t (hopc-j2s-flags))))
	    (("-fno-this" (help "Enable fast this access"))
	     (hopc-j2s-flags-set! (cons* :optim-this #f (hopc-j2s-flags))))
	    (("-fctor" (help "Enable fast constructor init sequences (-Ox)"))
	     (hopc-j2s-flags-set! (cons* :optim-ctor #t (hopc-j2s-flags))))
	    (("-fno-ctor" (help "Disable fast constructor init sequences"))
	     (hopc-j2s-flags-set! (cons* :optim-ctor #f (hopc-j2s-flags))))
	    (("-fcce" (help "Enable common inline caching (-Ox)"))
	     (hopc-j2s-flags-set! (cons* :optim-cce #t (hopc-j2s-flags))))
	    (("-fno-cce" (help "Disable common inline caching"))
	     (hopc-j2s-flags-set! (cons* :optim-cce #f (hopc-j2s-flags))))
	    (("-fliterals" (help "Enable literals optimization (-Ox)"))
	     (hopc-j2s-flags-set! (cons* :optim-literals #t (hopc-j2s-flags))))
	    (("-fno-literals" (help "Disable literals optimization"))
	     (hopc-j2s-flags-set! (cons* :optim-literals #f (hopc-j2s-flags))))
	    (("-fcache-level=?level" (help "Set cache inlining level"))
	     (when (>=fx (string->integer level) 2)
		(hopc-bigloo-options-set!
		   (cons* "-srfi" "cache-level2" (hopc-bigloo-options)))))
	    (("--profile" (help "Profiling mode"))
	     (hopc-j2s-flags-set! (cons* :profile #t (hopc-j2s-flags))))
	    (section "Experimental features")
	    (else
	     (if (string=? else "--")
		 (begin
		    (hopc-bigloo-options-set!
		       (append (hopc-bigloo-options) (cdr rest)))
		    (stop #t))
		 (hopc-sources-set! (append (hopc-sources) (list else)))))))
      (when loadp
	 (hopc-load-rc
	    (if (string? rc-file)
		rc-file
		(let ((path (make-file-name (hop-rc-directory) (hopc-rc-file))))
		   (if (file-exists? path)
		       path
		       (make-file-name (hop-etc-directory) (hopc-rc-file)))))))
      ;; long-size
      (unless (fixnum? (hopc-long-size))
	 (hopc-long-size-set! (bigloo-config 'elong-size)))
      exprs))

;*---------------------------------------------------------------------*/
;*    hopc-load-rc ...                                                 */
;*---------------------------------------------------------------------*/
(define (hopc-load-rc path)
   (if (string? path)
       (when (file-exists? path)
	  (hop-verb 2 "Loading `" path "'...\n")
	  (hop-load path :menv #unspecified))))      


