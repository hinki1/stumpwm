;;;; Copyright (C) 2016  Fredrik Tolf <fredrik@dolda2000.com>
;;;;
;;;;  This file is part of stumpwm.
;;;;
;;;; stumpwm is free software; you can redistribute it and/or modify
;;;; it under the terms of the GNU General Public License as published by
;;;; the Free Software Foundation; either version 2, or (at your option)
;;;; any later version.

;;;; stumpwm is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;;; GNU General Public License for more details.

;;;; You should have received a copy of the GNU General Public License
;;;; along with this software; see the file COPYING.  If not, see
;;;; <http://www.gnu.org/licenses/>.

(in-package :stumpwm)

;;;; This file implements a generic multiplexing I/O loop for listening
;;;; to I/O events from multiple sources. The model is as follows:
;;;;
;;;; An I/O multiplexer is represented as an object, with which I/O
;;;; channels can be registered to be monitored for events when the I/O
;;;; loop runs. An I/O channel is any object for which the generic
;;;; functions IO-CHANNEL-IOPORT, IO-CHANNEL-EVENTS and
;;;; IO-CHANNEL-HANDLE are implemented.
;;;;
;;;; IO-CHANNEL-IOPORT, given an I/O multiplexer and an I/O channel,
;;;; should return the underlying system I/O facility that the channel
;;;; operates on. The actual objects used to represent an I/O facility
;;;; depends on the Lisp implementation, operating system and the
;;;; specific I/O loop implementation, but, for example, on Unix
;;;; implementations they will likely be numeric file descriptors. The
;;;; I/O loop implementation implements IO-CHANNEL-IOPORT methods for
;;;; the facilities it understands (such as FD-STREAMs on SBCL), so
;;;; user-implemented channels should simply call IO-CHANNEL-IOPORT
;;;; recursively on whatever it operates on.
;;;;
;;;; IO-CHANNEL-EVENTS, given an I/O channel, should return a list of
;;;; the events that the channel is interested in. See the
;;;; documentation for IO-CHANNEL-EVENTS for further details.
;;;;
;;;; The I/O loop guarantees that it will check what events a channel
;;;; is interested in when it is first registered, and also at any time
;;;; the channel has been notified of an event. If the channel changes
;;;; its mind at any other point in time, it should use the
;;;; IO-LOOP-UPDATE function to notify the I/O loop of such
;;;; changes. The I/O loop may very well also update spuriously at
;;;; other times, but such updates are not guaranteed.
;;;;
;;;; IO-CHANNEL-HANDLE is called by the I/O loop to notify a channel of
;;;; an event.
;;;;
;;;; An I/O multiplexer is created with a MAKE-INSTANCE call on the
;;;; class of the desired multiplexer implementation. If the code using
;;;; the multiplexer has no certain preferences on an implementation
;;;; (which should be the usual case), the variable *DEFAULT-IO-LOOP*
;;;; points to a class that should be generally optimal given the
;;;; current Lisp implementation and operating system.
;;;;
;;;; Given a multiplexer, channels can be registered with it using
;;;; IO-LOOP-ADD, unregistered with IO-LOOP-REMOVE, and updated with
;;;; IO-LOOP-UPDATE (as described above). Call IO-LOOP on the
;;;; multiplexer to actually run it.

(export '(io-channel-ioport io-channel-events io-channel-handle
          io-loop io-loop-add io-loop-remove io-loop-update
          *default-io-loop* *current-io-loop*))

;;; General interface
(defgeneric io-channel-ioport (io-loop channel)
  (:documentation
   "Returns the I/O facility operated on by CHANNEL, in a
  representation understood by IO-LOOP. CHANNEL may be either an I/O
  channel or an object representing an underlying I/O facility, such
  as a stream object. An I/O loop implementation should implement
  methods for any primitive I/O facilities that it can monitor for
  events, and abstract channels should return whatever
  IO-CHANNEL-IOPORT returns for the primitive facility that it
  operates on.

  An I/O channel may also return NIL to indicate that it is only
  interested in purely virtual events, such as :TIMEOUT or :LOOP."))

(defgeneric io-channel-events (channel)
  (:documentation
   "Returns a list of events that CHANNEL is interested in. An event
  specification may be a simple symbol, or a list of a symbol and
  additional data for the event. Specific I/O loop implementations may
  implement additional events, but the following event specifications
  should be supported by all I/O loops:

      :READ -- The channel will be notified when its I/O port can be
      read from without blocking.

      :WRITE -- The channel will be notified when its I/O port can
      be written to without blocking.

      (:TIMEOUT TIME-SPEC) -- TIME-SPEC is a point in time in the
      same units as from (GET-INTERNAL-REAL-TIME), at which point
      the channel will be notified. It is permissible for TIME-SPEC
      to be a real number of any representation, but the system does
      not guarantee any particular level of accuracy.

      :LOOP -- The channel will be notifed for each iteration of the
      I/O loop, just before blocking for incoming events. This should
      be considered a hack to be avoided, but may be useful for
      certain libraries (such as XLIB).

  If, at any time, an empty list is returned, the channel is
  unregistered with the I/O loop.

  The I/O loop will check what events a channel is interested in when
  it is first registered with the loop, and whenever the channel has
  been notified of an event. If the channel changes its mind at any
  other point in time, it should use the IO-LOOP-UPDATE function to
  notify the I/O loop of such changes. The I/O loop may also update
  spuriously at any time, but such updates are not guaranteed."))

(defgeneric io-channel-handle (channel event &key &allow-other-keys)
  (:documentation
   "Called by the I/O loop to notify a channel that an event has
  occurred. EVENT is the symbol corresponding to the event
  specification from IO-CHANNEL-EVENTS (that is, :READ, :WRITE,
  :TIMEOUT or :LOOP). A number of keyword arguments with additional
  data specific to a certain event may also be passed, but no such
  arguments are currently defined."))

(defgeneric io-loop-add (io-loop channel)
  (:documentation "Add a channel to the given I/O multiplexer to be monitored."))

(defgeneric io-loop-remove (io-loop channel)
  (:documentation "Unregister a channel from the I/O multiplexer."))

(defgeneric io-loop-update (io-loop channel)
  (:documentation "Make the I/O loop update its knowledge of what
  events CHANNEL is interested in. See the documentation for
  IO-CHANNEL-EVENTS for more information."))

(defgeneric io-loop (io-loop &key &allow-other-keys)
  (:documentation "Run the given I/O multiplexer, watching for events
  on any channels registered with it. IO-LOOP will return when it has
  no channels left registered with it."))

(defvar *default-io-loop* 'sbcl-io-loop
  "The default I/O loop implementation. Should be generically optimal
  for the given LISP implementation and operating system.")

(defvar *current-io-loop* nil
  "Dynamically bound to the I/O loop currently running, providing an
  easy way for event callbacks to register new channels.")

;; Default methods for the above
(defmethod io-channel-handle (channel event &key &allow-other-keys)
  (declare (ignore channel event)))

;;; SBCL implementation
;;;
;;; It would be generally nice if SBCL supported epoll/kqueue, but it
;;; doesn't. The general I/O loop interface is consistent with such
;;; implementations, however, so if support is added at any time, it
;;; could be supported fairly easily.
;;;
;;; If need should arise, it should also be quite simple to add
;;; thread-safe operation.
(defclass sbcl-io-loop ()
  ((channels :initform '()))
  (:documentation
   "Implements a select(2)-based I/O loop for SBCL. The
  implementation is not particularly optimal, mostly because any
  efficiency ambitions are mostly pointless as long as SBCL lacks
  support for epoll/kqueue, but should work well enough for I/O loops
  with relatively few channels.

  The implementation currently supports monitoring SB-SYS:FD-STREAM
  and XLIB:DISPLAY objects."))

(defmethod io-loop-add ((info sbcl-io-loop) channel)
  (with-slots (channels) info
    (when (find channel channels)
      (error "I/O channel is already registered"))
    (push channel channels)))

(defmethod io-loop-remove ((info sbcl-io-loop) channel)
  (with-slots (channels) info
    (when (not (find channel channels))
      (error "I/O channel is not currently registered"))
    (setf channels (delete channel channels))))

(defmethod io-loop-update ((info sbcl-io-loop) channel)
  (declare (ignore info channel)))

;;; Calculates the maximum blocking time that can be spend  waiting for
;;; IO activity before channels interested in timeout events (i.e. timers)
;;; need to be notified.
(defun get-max-blocking-time (lowest-timeout)
  (declare (type (or null (integer 0)) lowest-timeout))
  (if lowest-timeout
    (let ((remaining (- lowest-timeout (get-internal-real-time))))
      (if (> remaining 0)
        (multiple-value-bind (whole-secs sub-sec)
                             (truncate (/ remaining internal-time-units-per-second))
          (values whole-secs (nth-value 0 (truncate (* sub-sec 1000000)))))
        (values 0 0)))
    (values nil nil)))

(defmethod io-loop ((info sbcl-io-loop) &key &allow-other-keys)
  (let ((*current-io-loop* info))
    (sb-alien:with-alien ((rfds (sb-alien:struct sb-unix:fd-set))
                          (wfds (sb-alien:struct sb-unix:fd-set))
                          (efds (sb-alien:struct sb-unix:fd-set)))
      (loop
        (let ((loop-channels nil)
              (read-channels nil)
              (write-channels nil)
              (timeout-channels nil)
              (inactive-channels nil)
              (highest-fd 0)
              (earliest-timeout nil))
          (sb-unix:fd-zero rfds)
          (sb-unix:fd-zero wfds)
          (sb-unix:fd-zero efds)

          ;; Collect the file descriptors we need to wait on in
          ;; the next step and the channels without any events
          ;; so we can remove them. Also group the active events
          ;; in categories.
          (dolist (ch (slot-value info 'channels))
            (if-let ((evs (io-channel-events ch)))
              (dolist (ev evs)
                (let ((ev-type (if (consp ev) (car ev) ev))
                      (ev-data (if (consp ev) (car (cdr ev)) nil))
                      (ev-fd (io-channel-ioport info ch)))
                  (case ev-type
                    (:loop
                     (push ch loop-channels))
                    (:read
                     (setf highest-fd (max highest-fd ev-fd))
                     (sb-unix:fd-set ev-fd rfds)
                     (push (cons ch ev-fd) read-channels))
                    (:write
                     (setf highest-fd (max highest-fd ev-fd))
                     (sb-unix:fd-set ev-fd wfds)
                     (push (cons ch ev-fd) write-channels))
                    (:timeout
                     (setf earliest-timeout (min (or earliest-timeout ev-data) ev-data))
                     (push (cons ch ev-data) timeout-channels)))))
                (push ch inactive-channels)))

          (dolist (ch inactive-channels)
            (io-loop-remove info ch))

          (unless (slot-value info 'channels)
            (return))

          ;; Notify the :LOOP channels before blocking.
          (dolist (ch loop-channels)
            (io-channel-handle ch :loop))

          ;; Block while waiting for something to happen on the
          ;; monitored file descriptors. This is implemented with
          ;; select(2). After that, notify the interested :READ
          ;; and :WRITE handlers.
          (multiple-value-bind (secs usecs)
                               (get-max-blocking-time earliest-timeout)
            (multiple-value-bind (count errno)
                                 (sb-unix:unix-fast-select
                                   (1+ highest-fd)
                                   (sb-alien:addr rfds)
                                   (sb-alien:addr wfds)
                                   (sb-alien:addr efds)
                                   secs
                                   usecs)
              (declare (ignore count))
              (if (and errno (plusp errno))
                (unless (eql errno sb-unix:eintr)
                  (dformat 1
                           "Unexpected ~S error: ~A~%"
                           'sb-unix:unix-fast-select
                           (sb-int:strerror errno)))
                (progn
                  (loop :for (ch . fd) :in read-channels
                        :do (when (or (sb-unix:fd-isset fd rfds)
                                      (sb-unix:fd-isset fd efds))
                              (io-channel-handle ch :read)))
                  (loop :for (ch . fd) :in write-channels
                        :do (when (sb-unix:fd-isset fd wfds)
                              (io-channel-handle ch :write)))))))

          ;; Notify all channels with now expired timeouts.
          (loop :with now = (get-internal-real-time)
                :for (ch . timeout) :in timeout-channels
                :do (when (<= timeout now)
                      (io-channel-handle ch :timeout))))))))
