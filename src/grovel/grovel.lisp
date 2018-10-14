;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; grovel.lisp --- The CFFI Groveller.
;;;
;;; Copyright (C) 2005-2006, Dan Knap <dankna@accela.net>
;;; Copyright (C) 2005-2006, Emily Backes <lucca@accela.net>
;;; Copyright (C) 2007, Stelian Ionescu <sionescu@cddr.org>
;;; Copyright (C) 2007, Luis Oliveira <loliveira@common-lisp.net>
;;;
;;; Permission is hereby granted, free of charge, to any person
;;; obtaining a copy of this software and associated documentation
;;; files (the "Software"), to deal in the Software without
;;; restriction, including without limitation the rights to use, copy,
;;; modify, merge, publish, distribute, sublicense, and/or sell copies
;;; of the Software, and to permit persons to whom the Software is
;;; furnished to do so, subject to the following conditions:
;;;
;;; The above copyright notice and this permission notice shall be
;;; included in all copies or substantial portions of the Software.
;;;
;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;;; NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
;;; HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
;;; WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
;;; DEALINGS IN THE SOFTWARE.
;;;

(in-package :iolib/grovel)

;;;# Utils

(defun trim-whitespace (strings)
  (loop for s in strings
        collect (string-trim '(#\Space #\Tab) s)))

(defun string* (s)
  "Coerce S to a string, making sure that it returns an extended string"
  (map 'string #'identity (string s)))

;;; Do we really want to suppress the output by default?
(defun invoke (command &rest args)
  (when (pathnamep command)
    (setf command (cffi-sys:native-namestring command)))
  (format *debug-io* "; ~A~{ ~A~}~%" command args)
  (multiple-value-bind (output stderr exit-code)
      (uiop:run-program (list* command args)
                        :output :string
                        :error-output :string
                        ;; We'll throw our own error
                        :ignore-error-status t)
    (unless (zerop exit-code)
      (grovel-error "External process exited with code ~S.~@
                     Command was: ~S~{ ~S~}~@
                     Output was:~%~A~@
                     Error output was:~%~A"
                    exit-code command args output stderr))
    output))

;;;# Error Conditions

(define-condition grovel-error (simple-error) ())

(defun grovel-error (format-control &rest format-arguments)
  (error 'grovel-error
         :format-control format-control
         :format-arguments format-arguments))

;;; This warning is signalled when iolib-grovel can't find some macro.
;;; Signalled by CONSTANT or CONSTANTENUM.
(define-condition missing-definition (warning)
  ((%name :initarg :name :reader name-of))
  (:report (lambda (condition stream)
             (format stream "No definition for ~A"
                     (name-of condition)))))

;;;# Grovelling

;;; The header of the intermediate C file.
(defparameter *header*
  "/*
 * This file has been automatically generated by iolib-grovel.
 * Do not edit it by hand.
 */

")

;;; C code generated by iolib-grovel is inserted between the contents
;;; of *PROLOGUE* and *POSTSCRIPT*, inside the main function's body.

(defparameter *prologue*
  "
#include <grovel-common.h>

int main(int argc, char**argv) {
  int autotype_tmp;
  FILE *output = argc > 1 ? fopen(argv[1], \"w\") : stdout;
  fprintf(output, \";;;; This file has been automatically generated by \"
                  \"iolib-grovel.\\n;;;; Do not edit it by hand.\\n\\n\");

")

(defparameter *postscript*
  "
  if  (output != stdout)
    fclose(output);
  return 0;
}
")

(defun unescape-for-c (text)
  (with-output-to-string (result)
    (loop for i below (length text)
          for char = (char text i) do
          (cond ((eql char #\") (princ "\\\"" result))
                ((eql char #\newline) (princ "\\n" result))
                (t (princ char result))))))

(defun c-format (out fmt &rest args)
  (let ((text (unescape-for-c (format nil "~?" fmt args))))
    (format out "~&  fputs(\"~A\", output);~%" text)))

(defun c-printf (out fmt &rest args)
  (flet ((item (item)
           (format out "~A" (unescape-for-c (format nil item)))))
    (format out "~&  fprintf(output, \"")
    (item fmt)
    (format out "\"")
    (loop for arg in args do
          (format out ", ")
          (item arg))
    (format out ");~%")))

;;; TODO: handle packages in a better way. One way is to process each
;;; grovel form as it is read (like we already do for wrapper
;;; forms). This way in can expect *PACKAGE* to have sane values.
;;; This would require that "header forms" come before any other
;;; forms.
(defun c-print-symbol (out symbol &optional no-package)
  (c-format out
            (let ((package (symbol-package symbol)))
              (cond
                ((eq (find-package '#:keyword) package) ":~(~A~)")
                (no-package "~(~A~)")
                ((eq (find-package '#:cl) package) "cl:~(~A~)")
                (t "~(~A~)")))
            symbol))

(defun c-write (out form &key recursive)
  (cond
    ((and (listp form)
          (eq 'quote (car form)))
     (c-format out "'")
     (c-write out (cadr form) :recursive t))
    ((listp form)
     (c-format out "(")
     (loop for subform in form
           for first-p = t then nil
           unless first-p do (c-format out " ")
           do (c-write out subform :recursive t))
     (c-format out ")"))
    ((symbolp form)
     (c-print-symbol out form)))
  (unless recursive
    (c-format out "~%")))

;;; Always NIL for now, add {ENABLE,DISABLE}-AUTO-EXPORT grovel forms
;;; later, if necessary.
(defvar *auto-export* nil)

(defun c-export (out symbol)
  (when (and *auto-export* (not (keywordp symbol)))
    (c-format out "(cl:export '")
    (c-print-symbol out symbol t)
    (c-format out ")~%")))

(defun c-section-header (out section-type section-symbol)
  (format out "~%  /* ~A section for ~S */~%"
          section-type
          section-symbol))

(defun remove-suffix (string suffix)
  (let ((suffix-start (- (length string) (length suffix))))
    (if (and (> suffix-start 0)
             (string= string suffix :start1 suffix-start))
        (subseq string 0 suffix-start)
        string)))

(defun strcat (&rest strings)
  (apply #'concatenate 'string strings))

(defgeneric %process-grovel-form (name out arguments)
  (:method (name out arguments)
    (declare (ignore out arguments))
    (grovel-error "Unknown Grovel syntax: ~S" name)))

(defun process-grovel-form (out form)
  (%process-grovel-form (form-kind form) out (cdr form)))

(defun form-kind (form)
  ;; Using INTERN here instead of FIND-SYMBOL will result in less
  ;; cryptic error messages when an undefined grovel/wrapper form is
  ;; found.
  (intern (symbol-name (car form)) '#:iolib-grovel))

(defvar *header-forms* '(c include define flag typedef))

(defun header-form-p (form)
  (member (form-kind form) *header-forms*))

(defun make-c-file-name (output-defaults)
  (make-pathname :type "cc" :defaults output-defaults))

(defun generate-c-file (input-file output-defaults)
  (let ((c-file (make-c-file-name output-defaults)))
    (with-open-file (out c-file :direction :output :if-exists :supersede)
      (with-open-file (in input-file :direction :input)
        (flet ((read-forms (s)
                 (do ((forms ())
                      (form (read s nil nil) (read s nil nil)))
                     ((null form) (nreverse forms))
                   (labels
                       ((process-form (f)
                          (case (form-kind f)
                            (flag (warn "Groveler clause FLAG is deprecated, use CC-FLAGS instead.")))
                          (case (form-kind f)
                            (in-package
                             (setf *package* (find-package (second f)))
                             (push f forms))
                            (progn
                              ;; flatten progn forms
                              (mapc #'process-form (rest f)))
                            (t (push f forms)))))
                     (process-form form)))))
          (let* ((forms (read-forms in))
                 (header-forms (remove-if-not #'header-form-p forms))
                 (body-forms (remove-if #'header-form-p forms)))
            (write-string *header* out)
            (dolist (form header-forms)
              (process-grovel-form out form))
            (write-string *prologue* out)
            (dolist (form body-forms)
              (process-grovel-form out form))
            (write-string *postscript* out)))))
    c-file))

(defparameter *exe-extension*
  (fcase
    (:windows "exe")
    (t        nil)))

(defun exe-filename (defaults)
  (let ((path (make-pathname :type *exe-extension*
                             :defaults defaults)))
    ;; It's necessary to prepend "./" to relative paths because some
    ;; implementations of INVOKE use a shell.
    (when (or (not (pathname-directory path))
              (eq :relative (car (pathname-directory path))))
      (setf path (make-pathname
                  :directory (list* :relative "."
                                    (cdr (pathname-directory path)))
                  :defaults path)))
    path))

(defun tmp-lisp-filename (defaults)
  (make-pathname :name (strcat (pathname-name defaults) ".grovel-tmp")
                 :type "lisp" :defaults defaults))

(cffi:defcfun "getenv" :string
  (name :string))


(defun parse-command-line (s)
  (split-sequence #\Space s :remove-empty-subseqs t))

(defparameter *cxx*
  (fcase
    (:freebsd "clang++")
    ((or :cygwin (not (or :windows :freebsd))) "g++")
    ((and :windows (not :cygwin)) "c:/msys/1.0/bin/g++.exe")))

(defparameter *cc-flags*
  (append
   (list "-Wno-write-strings")
   ;; ECL internal flags
   #+ecl (parse-command-line c::*cc-flags*)
   (fcase
     ;; For MacPorts
     (:darwin '("-I" "/opt/local/include/"))
     ;; FreeBSD non-base header files
     ;; DragonFly Dports install software in /usr/local
     ;; And what about pkgsrc?
     ((or :freebsd :dragonfly :bsd) '("-I" "/usr/local/include/"))
     (t '()))))

;;; FIXME: is there a better way to detect whether these flags
;;; are necessary?
(defparameter *cpu-word-size-flags*
  (fcase
    ((or :x86 :x86-64 :sparc :sparc64)
     (ecase (cffi:foreign-type-size :pointer)
       (4 (list "-m32"))
       (8 (list "-m64"))))
    (:arm '("-marm"))
    (t    '())))

(defparameter *platform-library-flags*
  (list #+darwin "-bundle"
        #-darwin "-shared"
        #-windows "-fPIC"))

(defun cc-compile-and-link (input-file output-file &key library)
  (let ((arglist
         `(,(or (getenv "CXX") *cxx*)
           ,@*cpu-word-size-flags*
           ,@*cc-flags*
           ;; add the cffi directory to the include path to make common.h visible
           ,(format nil "-I~A"
                    (directory-namestring
                     (asdf:component-pathname
                      (asdf:find-system :iolib.grovel))))
           ,@(when library *platform-library-flags*)
           "-o" ,(native-namestring output-file)
           ,(native-namestring input-file))))
    (when library
      ;; if it's a library that may be used, remove it
      ;; so we won't possibly be overwriting the code of any existing process
      (ignore-some-conditions (file-error)
        (delete-file output-file)))
    (apply #'invoke arglist)))

;;; *PACKAGE* is rebound so that the IN-PACKAGE form can set it during
;;; *the extent of a given grovel file.
(defun process-grovel-file (input-file &optional (output-defaults input-file))
  (with-standard-io-syntax
    (let* ((*print-readably* nil)
           (c-file (generate-c-file input-file output-defaults))
           (exe-file (exe-filename c-file))
           (lisp-file (tmp-lisp-filename c-file)))
      (cc-compile-and-link c-file exe-file)
      (invoke exe-file (native-namestring lisp-file))
      lisp-file)))

;;; OUT is lexically bound to the output stream within BODY.
(defmacro define-grovel-syntax (name lambda-list &body body)
  (with-unique-names (name-var args)
    `(defmethod %process-grovel-form ((,name-var (eql ',name)) out ,args)
       (declare (ignorable out))
       (destructuring-bind ,lambda-list ,args
         ,@body))))

(define-grovel-syntax c (body)
  (format out "~%~A~%" body))

(define-grovel-syntax include (&rest includes)
  (format out "~{#include <~A>~%~}" includes))

(define-grovel-syntax define (name &optional value)
  (format out "#define ~A~@[ ~A~]~%" name value))

(define-grovel-syntax typedef (base-type new-type)
  (format out "typedef ~A ~A;~%" base-type new-type))

;;; Is this really needed?
(define-grovel-syntax ffi-typedef (new-type base-type)
  (c-format out "(cffi:defctype ~S ~S)~%" new-type base-type))

(define-grovel-syntax flag (&rest flags)
  (appendf *cc-flags* (trim-whitespace flags)))

(define-grovel-syntax cc-flags (&rest flags)
  (appendf *cc-flags* (trim-whitespace flags)))

;;; This form also has some "read time" effects. See GENERATE-C-FILE.
(define-grovel-syntax in-package (name)
  (c-format out "(cl:in-package ~S)~%~%" (string* name)))

(define-grovel-syntax ctype (lisp-name c-name)
  (c-section-header out "ctype" lisp-name)
  (format out "  CFFI_DEFCTYPE(~S, ~A);~%"
          (string* lisp-name) c-name))

(defun docstring-to-c (docstring)
  (if docstring (format nil "~S" docstring) "NULL"))

(define-grovel-syntax constant ((lisp-name &rest c-names) &key documentation optional)
  (c-section-header out "constant" lisp-name)
  (loop :for i :from 0
        :for c-name :in c-names :do
        (format out "~A defined(~A)~%" (if (zerop i) "#if" "#elif") c-name)
        (format out "  CFFI_DEFCONSTANT(~S, ~A, ~A);~%"
                (string* lisp-name) c-name
                (docstring-to-c documentation)))
  (unless optional
    (format out "#else~%  cffi_signal_missing_definition(output, ~S);~%"
            (string* lisp-name)))
  (format out "#endif~%"))

(define-grovel-syntax cunion (union-lisp-name union-c-name &rest slots)
  (let ((documentation (when (stringp (car slots)) (pop slots))))
    (c-section-header out "cunion" union-lisp-name)
    (format out "  CFFI_DEFCUNION_START(~S, ~A, ~A);~%"
            (string* union-lisp-name) union-c-name
            (docstring-to-c documentation))
    (dolist (slot slots)
      (destructuring-bind (slot-lisp-name slot-c-name &key type (count 1))
          slot
        (etypecase count
          ((eql :auto)
           (format out "  CFFI_DEFCUNION_SLOT_AUTO(~A, ~A, ~S, ~S);~%"
                   union-c-name slot-c-name
                   (prin1-to-string slot-lisp-name) (prin1-to-string type)))
          ((or integer symbol string)
           (format out "  CFFI_DEFCUNION_SLOT(~A, ~A, ~S, ~S, ~A);~%"
                   union-c-name slot-c-name
                   (prin1-to-string slot-lisp-name) (prin1-to-string type) count)))))
    (format out "  CFFI_DEFCUNION_END;~%")
    (format out "  CFFI_DEFTYPEDEF(~S, ~S);~%"
            (string* union-lisp-name) (string* :union))
    (format out "  CFFI_DEFTYPESIZE(~S, ~A);~%"
            (string* union-lisp-name) union-c-name)))

(defun make-from-pointer-function-name (type-name)
  (symbolicate '#:make- type-name '#:-from-pointer))

;;; DEFINE-C-STRUCT-WRAPPER (in ../src/types.lisp) seems like a much
;;; cleaner way to do this.  Unless I can find any advantage in doing
;;; it this way I'll delete this soon.  --luis
(define-grovel-syntax cstruct-and-class-item (&rest arguments)
  (process-grovel-form out (cons 'cstruct arguments))
  (destructuring-bind (struct-lisp-name struct-c-name &rest slots)
      arguments
    (declare (ignore struct-c-name))
    (let* ((slot-names (mapcar #'car slots))
           (reader-names (mapcar
                          (lambda (slot-name)
                            (intern
                             (strcat (symbol-name struct-lisp-name) "-"
                                     (symbol-name slot-name))))
                          slot-names))
           (initarg-names (mapcar
                           (lambda (slot-name)
                             (intern (symbol-name slot-name) "KEYWORD"))
                           slot-names))
           (slot-decoders (mapcar (lambda (slot)
                                    (destructuring-bind
                                          (lisp-name c-name
                                                     &key type count
                                                     &allow-other-keys)
                                        slot
                                      (declare (ignore lisp-name c-name))
                                      (cond ((and (eq type :char) count)
                                             'cffi:foreign-string-to-lisp)
                                            (t nil))))
                                  slots))
           (defclass-form
            `(defclass ,struct-lisp-name ()
               ,(mapcar (lambda (slot-name initarg-name reader-name)
                          `(,slot-name :initarg ,initarg-name
                                       :reader ,reader-name))
                        slot-names
                        initarg-names
                        reader-names)))
           (make-function-name
            (make-from-pointer-function-name struct-lisp-name))
           (make-defun-form
            ;; this function is then used as a constructor for this class.
            `(defun ,make-function-name (pointer)
               (cffi:with-foreign-slots
                   (,slot-names pointer ,struct-lisp-name)
                 (make-instance ',struct-lisp-name
                                ,@(loop for slot-name in slot-names
                                        for initarg-name in initarg-names
                                        for slot-decoder in slot-decoders
                                        collect initarg-name
                                        if slot-decoder
                                        collect `(,slot-decoder ,slot-name)
                                        else collect slot-name))))))
      (c-write out defclass-form)
      (c-write out make-defun-form))))

(define-grovel-syntax cstruct (struct-lisp-name struct-c-name &rest slots)
  (let ((documentation (when (stringp (car slots)) (pop slots))))
    (c-section-header out "cstruct" struct-lisp-name)
    (format out "  CFFI_DEFCSTRUCT_START(~S, ~A, ~A);~%"
            (string* struct-lisp-name) struct-c-name
            (docstring-to-c documentation))
    (dolist (slot slots)
      (destructuring-bind (slot-lisp-name slot-c-name &key type (count 1))
          slot
        (etypecase count
          ((eql :auto)
           (format out "  CFFI_DEFCSTRUCT_SLOT_AUTO(~A, ~A, ~S, ~S);~%"
                   struct-c-name slot-c-name
                   (prin1-to-string slot-lisp-name) (prin1-to-string type)))
          ((or integer symbol string)
           (format out "  CFFI_DEFCSTRUCT_SLOT(~A, ~A, ~S, ~S, ~A);~%"
                   struct-c-name slot-c-name
                   (prin1-to-string slot-lisp-name) (prin1-to-string type) count)))))    
    (format out "  CFFI_DEFCSTRUCT_END;~%")
    (format out "  CFFI_DEFTYPEDEF(~S, ~S);~%"
            (string* struct-lisp-name) (string* :struct))
    (format out "  CFFI_DEFTYPESIZE(~S, ~A);~%"
            (string* struct-lisp-name) struct-c-name)))

(defun foreign-name-to-symbol (s)
  (intern (substitute #\- #\_ (string-upcase s))))

(defun choose-lisp-and-foreign-names (string-or-list)
  (etypecase string-or-list
    (string (values string-or-list (foreign-name-to-symbol string-or-list)))
    (list (destructuring-bind (fname lname &rest args) string-or-list
            (declare (ignore args))
            (assert (and (stringp fname) (symbolp lname)))
            (values fname lname)))))

(define-grovel-syntax cenum (name &rest enum-list)
  (let ((documentation (when (stringp (car enum-list)) (pop enum-list))))
    (destructuring-bind (name &key (base-type :int) define-constants)
        (ensure-list name)
      (c-section-header out "cenum" name)
      (format out "  CFFI_DEFCENUM_START(~S, ~S, ~A);~%"
              (string* name) (prin1-to-string base-type)
              (docstring-to-c documentation))
      (dolist (enum enum-list)
        (destructuring-bind (lisp-name c-name &key documentation)
            enum
          (check-type lisp-name keyword)
          (format out "  CFFI_DEFCENUM_MEMBER(~S, ~A, ~A);~%"
                  (prin1-to-string lisp-name) c-name
                  (docstring-to-c documentation))))
      (format out "  CFFI_DEFCENUM_END;~%")
      (when define-constants
        (define-constants-from-enum out enum-list)))))

(define-grovel-syntax constantenum (name &rest enum-list)
  (let ((documentation (when (stringp (car enum-list)) (pop enum-list))))
    (destructuring-bind (name &key (base-type :int) define-constants)
        (ensure-list name)
      (c-section-header out "constantenum" name)
      (format out "  CFFI_DEFCENUM_START(~S, ~S, ~A);~%"
              (string* name) (prin1-to-string base-type)
              (docstring-to-c documentation))
      (dolist (enum enum-list)
        (destructuring-bind (lisp-name c-name &key documentation optional)
            enum
          (check-type lisp-name keyword)
          (when optional
            (format out "#if defined(~A)~%" c-name))
          (format out "  CFFI_DEFCENUM_MEMBER(~S, ~A, ~A);~%"
                  (prin1-to-string lisp-name) c-name
                  (docstring-to-c documentation))
          (when optional
            (format out "#endif~%"))))
      (format out "  CFFI_DEFCENUM_END;~%")
      (when define-constants
        (define-constants-from-enum out enum-list)))))

(defun define-constants-from-enum (out enum-list)
  (dolist (enum enum-list)
    (destructuring-bind (lisp-name c-name &key documentation optional)
        enum
      (process-grovel-form
       out `(constant (,lisp-name ,c-name)
                      ,@(if documentation (list :documentation t))
                      ,@(if optional (list :optional t)))))))


;;;# Wrapper Generation
;;;
;;; Here we generate a C file from a s-exp specification but instead
;;; of compiling and running it, we compile it as a shared library
;;; that can be subsequently loaded with LOAD-FOREIGN-LIBRARY.
;;;
;;; Useful to get at macro functionality, errno, system calls,
;;; functions that handle structures by value, etc...
;;;
;;; Matching CFFI bindings are generated along with said C file.

(defun process-wrapper-form (out form)
  (%process-wrapper-form (form-kind form) out (cdr form)))

;;; The various operators push Lisp forms onto this list which will be
;;; written out by PROCESS-WRAPPER-FILE once everything is processed.
(defvar *lisp-forms*)

(defun generate-c-lib-file (input-file output-defaults)
  (let ((*lisp-forms* nil)
        (c-file (make-c-file-name output-defaults)))
    (with-open-file (out c-file :direction :output :if-exists :supersede)
      (with-open-file (in input-file :direction :input)
        (write-string *header* out)
        (loop for form = (read in nil nil) while form
              do (process-wrapper-form out form))))
    (values c-file (nreverse *lisp-forms*))))

(defun lib-filename (defaults)
  (make-pathname :type (subseq (cffi::default-library-suffix) 1)
                 :defaults defaults))

(defun generate-bindings-file (lib-file lib-soname lisp-forms output-defaults)
  (let ((lisp-file (tmp-lisp-filename output-defaults)))
    (with-open-file (out lisp-file :direction :output :if-exists :supersede)
      (format out ";;;; This file was automatically generated by iolib-grovel.~%~
                   ;;;; Do not edit by hand.~%")
      (let ((*package* (find-package '#:cl))
            (named-library-name
             (let ((*package* (find-package :keyword))
                   (*read-eval* nil))
               (read-from-string lib-soname))))
        (pprint `(progn
                   (cffi:define-foreign-library
                       (,named-library-name
                        :type :grovel-wrapper
                        :search-path ,(directory-namestring lib-file))
                     (t ,(namestring (lib-filename lib-soname))))
                   (cffi:use-foreign-library ,named-library-name))
                out)
        (fresh-line out))
      (dolist (form lisp-forms)
        (print form out))
      (terpri out))
    lisp-file))

(defun make-soname (lib-soname output-defaults)
  (make-pathname :name lib-soname
                 :defaults output-defaults))

;;; *PACKAGE* is rebound so that the IN-PACKAGE form can set it during
;;; *the extent of a given wrapper file.
(defun process-wrapper-file (input-file output-defaults lib-soname)
  (with-standard-io-syntax
    (let ((*print-readably* nil)
          (lib-file
            (lib-filename (make-soname lib-soname output-defaults))))
      (multiple-value-bind (c-file lisp-forms)
          (generate-c-lib-file input-file output-defaults)
        (cc-compile-and-link c-file lib-file :library t)
        ;; FIXME: hardcoded library path.
        (values (generate-bindings-file lib-file lib-soname lisp-forms output-defaults)
                lib-file)))))

(defgeneric %process-wrapper-form (name out arguments)
  (:method (name out arguments)
    (declare (ignore out arguments))
    (grovel-error "Unknown Grovel syntax: ~S" name)))

;;; OUT is lexically bound to the output stream within BODY.
(defmacro define-wrapper-syntax (name lambda-list &body body)
  (with-unique-names (name-var args)
    `(defmethod %process-wrapper-form ((,name-var (eql ',name)) out ,args)
       (declare (ignorable out))
       (destructuring-bind ,lambda-list ,args
         ,@body))))

(define-wrapper-syntax progn (&rest forms)
  (dolist (form forms)
    (process-wrapper-form out form)))

(define-wrapper-syntax in-package (name)
  (setq *package* (find-package name))
  (push `(in-package ,name) *lisp-forms*))

(define-wrapper-syntax c (&rest strings)
  (dolist (string strings)
    (write-line string out)))

(define-wrapper-syntax flag (&rest flags)
  (appendf *cc-flags* (trim-whitespace flags)))

(define-wrapper-syntax proclaim (&rest proclamations)
  (push `(proclaim ,@proclamations) *lisp-forms*))

(define-wrapper-syntax declaim (&rest declamations)
  (push `(declaim ,@declamations) *lisp-forms*))

(define-wrapper-syntax define (name &optional value)
  (format out "#define ~A~@[ ~A~]~%" name value))

(define-wrapper-syntax include (&rest includes)
  (format out "~{#include <~A>~%~}" includes))

;;; FIXME: this function is not complete.  Should probably follow
;;; typedefs?  Should definitely understand pointer types.
(defun c-type-name (typespec)
  (let ((spec (ensure-list typespec)))
    (if (stringp (car spec))
        (car spec)
        (case (car spec)
          ((:uchar :unsigned-char) "unsigned char")
          ((:unsigned-short :ushort) "unsigned short")
          ((:unsigned-int :uint) "unsigned int")
          ((:unsigned-long :ulong) "unsigned long")
          ((:long-long :llong) "long long")
          ((:unsigned-long-long :ullong) "unsigned long long")
          (:pointer "void*")
          (:string "char*")
          (t (cffi::foreign-name (car spec) nil))))))

(defun cffi-type (typespec)
  (if (and (listp typespec) (stringp (car typespec)))
      (second typespec)
      typespec))

(defun symbol* (s)
  (check-type s (and symbol (not null)))
  s)

(define-wrapper-syntax defwrapper (name-and-options rettype &rest args)
  (multiple-value-bind (lisp-name foreign-name options)
      (cffi::parse-name-and-options name-and-options)
    (let* ((foreign-name-wrap (strcat foreign-name "_cffi_wrap"))
           (fargs (mapcar (lambda (arg)
                            (list (c-type-name (second arg))
                                  (cffi::foreign-name (first arg) nil)))
                          args))
           (fargnames (mapcar #'second fargs)))
      ;; output C code
      (format out "~A ~A" (c-type-name rettype) foreign-name-wrap)
      (format out "(~{~{~A ~A~}~^, ~})~%" fargs)
      (format out "{~%  return ~A(~{~A~^, ~});~%}~%~%" foreign-name fargnames)
      ;; matching bindings
      (push `(cffi:defcfun (,foreign-name-wrap ,lisp-name ,@options)
                 ,(cffi-type rettype)
               ,@(mapcar (lambda (arg)
                           (list (symbol* (first arg))
                                 (cffi-type (second arg))))
                         args))
            *lisp-forms*))))

(define-wrapper-syntax defwrapper* (name-and-options rettype args &rest c-lines)
  ;; output C code
  (multiple-value-bind (lisp-name foreign-name options)
      (cffi::parse-name-and-options name-and-options)
    (let ((foreign-name-wrap (strcat foreign-name "_cffi_wrap"))
          (fargs (mapcar (lambda (arg)
                           (list (c-type-name (second arg))
                                 (cffi::foreign-name (first arg) nil)))
                         args)))
      (format out "~A ~A" (c-type-name rettype)
              foreign-name-wrap)
      (format out "(~{~{~A ~A~}~^, ~})~%" fargs)
      (format out "{~%~{  ~A~%~}}~%~%" c-lines)
      ;; matching bindings
      (push `(cffi:defcfun (,foreign-name-wrap ,lisp-name ,@options)
                 ,(cffi-type rettype)
               ,@(mapcar (lambda (arg)
                           (list (symbol* (first arg))
                                 (cffi-type (second arg))))
                         args))
            *lisp-forms*))))
