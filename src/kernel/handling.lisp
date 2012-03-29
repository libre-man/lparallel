;;; Copyright (c) 2011-2012, James M. Lawrence. All rights reserved.
;;; 
;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:
;;; 
;;;     * Redistributions of source code must retain the above copyright
;;;       notice, this list of conditions and the following disclaimer.
;;; 
;;;     * Redistributions in binary form must reproduce the above
;;;       copyright notice, this list of conditions and the following
;;;       disclaimer in the documentation and/or other materials provided
;;;       with the distribution.
;;; 
;;;     * Neither the name of the project nor the names of its
;;;       contributors may be used to endorse or promote products derived
;;;       from this software without specific prior written permission.
;;; 
;;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;; "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;; LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;; A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;; HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;; SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
;;; LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
;;; DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
;;; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
;;; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
;;; OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

(in-package #:lparallel.kernel)

(defvar *debugger-lock* (make-recursive-lock)
  "Global. For convenience -- allows only one debugger prompt at a
time from errors signaled inside `call-with-kernel-handler'.")

(defslots wrapped-error ()
  ((object :type condition))
  (:documentation
   "This is a container for transferring an error that occurs inside
   `call-with-kernel-handler' to the calling thread."))

(defun wrap-error (error-name)
  (make-wrapped-error-instance :object (make-condition error-name)))

(defgeneric unwrap-result (result)
  (:documentation
   "In `receive-result', this is called on the stored task result.
   The user receives the return value of this function."))

(defmethod unwrap-result (result)
  "Most objects unwrap to themselves."
  result)

(defmethod unwrap-result ((result wrapped-error))
  "A `wrapped-error' signals an error upon being unwrapped."
  (with-wrapped-error-slots (object) result
    (error object)))

(defmacro kernel-handler-bind (clauses &body body)
  "Like `handler-bind' but reaches into kernel worker threads."
  (let1 forms (loop
                 :for clause :in clauses
                 :for (name fn more) := clause
                 :do (unless (and (symbolp name) (not more))
                       (error "Wrong format in `kernel-handler-bind' clause: ~a"
                              clause))
                 :collect `(cons ',name ,fn))
    `(let1 *client-handlers* (nconc (list ,@forms) *client-handlers*)
       ,@body)))

(defun condition-handler (con)
  "Mimic the CL handling mechanism, calling handlers until one assumes
control (or not)."
  (loop
     :for (name . fn)  :in *client-handlers*
     :for (nil . tail) :on *client-handlers*
     :do (when (subtypep (type-of con) name)
           (let1 *client-handlers* tail
             (handler-bind ((condition #'condition-handler))
               (funcall fn con))))))

(defun make-debugger-hook ()
  "Allow one debugger prompt at a time from worker threads."
  (if *debugger-hook*
      (let1 previous-hook *debugger-hook*
        (lambda (condition self)
          (let1 *debugger-error* condition
            (with-recursive-lock-held (*debugger-lock*)
              (funcall previous-hook condition self)))))
      (lambda (condition self)
        (declare (ignore self))
        (let1 *debugger-error* condition
          (with-recursive-lock-held (*debugger-lock*)
            (invoke-debugger condition))))))

(defmacro with-task-context (&body body)
  `(catch 'current-task
     ,@body))

(defun transfer-error-restart (&optional (err *debugger-error*))
  (throw 'current-task
    (make-wrapped-error-instance
     :object (ctypecase err
               (condition err)
               (symbol (make-condition err))))))

(defun transfer-error-report (stream)
  (format stream "Transfer this error to dependent threads, if any."))

(defun %call-with-kernel-handler (fn)
  (let ((*handler-active-p* t)
        (*debugger-hook* (make-debugger-hook)))
    (handler-bind ((condition #'condition-handler))
      (restart-bind ((transfer-error #'transfer-error-restart
                       :report-function #'transfer-error-report))
        (funcall fn)))))

(defun call-with-kernel-handler (fn)
  (with-task-context
    (if *handler-active-p*
        (funcall fn)
        (%call-with-kernel-handler fn))))

(define-condition task-killed-error (error) ())

(define-condition no-kernel-error (error) ()
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (format stream
"Welcome to lparallel. To get started, you need to create some worker
threads. Choose the MAKE-KERNEL restart to create them now.

Worker threads are asleep when not in use. They are typically created
once per Lisp session.

Adding the following line to your startup code will prevent this
message from appearing in the future (N is the number of workers):

  (setf lparallel:*kernel* (lparallel:make-kernel N))
")))
  (:documentation "Error signaled when `*kernel*' is nil."))