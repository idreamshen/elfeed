;;; elfeed-show.el --- display feed entries -*- lexical-binding: t; -*-

;; This is free and unencumbered software released into the public domain.

;;; Code:

(require 'cl-lib)
(require 'shr)
(require 'url-parse)
(require 'browse-url)
(require 'message) ; faces

(require 'elfeed)
(require 'elfeed-db)
(require 'elfeed-lib)
(require 'elfeed-search)

(defcustom elfeed-show-truncate-long-urls t
  "When non-nil, use an ellipsis to shorten very long displayed URLs."
  :group 'elfeed
  :type 'boolean)

(defcustom elfeed-show-entry-author t
  "When non-nil, show the entry's author (if it's in the entry's metadata)."
  :group 'elfeed
  :type 'boolean)

(defvar elfeed-show-entry nil
  "The entry being displayed in this buffer.")

(defvar elfeed-show-entry-switch #'switch-to-buffer
  "Function to call to display and switch to the feed entry buffer.
Defaults to `switch-to-buffer'.")

(defvar elfeed-show-entry-delete #'elfeed-kill-buffer
  "Function called when quitting from the elfeed-entry
buffer. Does not take any arguments.

Defaults to `elfeed-kill-buffer'.")

(defvar elfeed-show-refresh-function #'elfeed-show-refresh--mail-style
  "Function called to refresh the `*elfeed-entry*' buffer.")

(defvar elfeed-show-mode-map
  (let ((map (make-sparse-keymap)))
    (prog1 map
      (suppress-keymap map)
      (define-key map "d" #'elfeed-show-save-enclosure)
      (define-key map "q" #'elfeed-kill-buffer)
      (define-key map "g" #'elfeed-show-refresh)
      (define-key map "n" #'elfeed-show-next)
      (define-key map "p" #'elfeed-show-prev)
      (define-key map "s" #'elfeed-show-new-live-search)
      (define-key map "b" #'elfeed-show-visit)
      (define-key map "y" #'elfeed-show-yank)
      (define-key map "u" #'elfeed-show-tag--unread)
      (define-key map "+" #'elfeed-show-tag)
      (define-key map "-" #'elfeed-show-untag)
      (define-key map (kbd "SPC") #'scroll-up-command)
      (define-key map (kbd "DEL") #'scroll-down-command)
      (define-key map (kbd "TAB") #'elfeed-show-next-link)
      (define-key map "\e\t" #'shr-previous-link)
      (define-key map [backtab] #'shr-previous-link)
      (define-key map [mouse-2] #'shr-browse-url)
      (define-key map "A" #'elfeed-show-add-enclosure-to-playlist)
      (define-key map "P" #'elfeed-show-play-enclosure)))
  "Keymap for `elfeed-show-mode'.")

(defun elfeed-show-mode ()
  "Mode for displaying Elfeed feed entries.
\\{elfeed-show-mode-map}"
  (interactive)
  (kill-all-local-variables)
  (use-local-map elfeed-show-mode-map)
  (setq major-mode 'elfeed-show-mode
        mode-name "elfeed-show"
        buffer-read-only t)
  (buffer-disable-undo)
  (make-local-variable 'elfeed-show-entry)
  (run-mode-hooks 'elfeed-show-mode-hook))

(defalias 'elfeed-show-tag--unread
  (elfeed-expose #'elfeed-show-tag 'unread)
  "Mark the current entry unread.")

(defun elfeed-insert-html (html &optional base-url)
  "Converted HTML markup to a propertized string."
  (shr-insert-document
   (if (elfeed-libxml-supported-p)
       (with-temp-buffer
         ;; insert <base> to work around libxml-parse-html-region bug
         (when base-url
           (insert (format "<base href=\"%s\">" base-url)))
         (insert html)
         (libxml-parse-html-region (point-min) (point-max) base-url))
     '(i () "Elfeed: libxml2 functionality is unavailable"))))

(cl-defun elfeed-insert-link (url &optional (content url))
  "Insert a clickable hyperlink to URL titled CONTENT."
  (when (and elfeed-show-truncate-long-urls
             (integerp shr-width)
             (> (length content) (- shr-width 8)))
    (let ((len (- (/ shr-width 2) 10)))
      (setq content (format "%s[...]%s"
                            (substring content 0 len)
                            (substring content (- len))))))
  (elfeed-insert-html (format "<a href=\"%s\">%s</a>" url content)))

(defun elfeed-compute-base (url)
  "Return the base URL for URL, useful for relative paths."
  (let ((obj (url-generic-parse-url url)))
    (setf (url-filename obj) nil)
    (setf (url-target obj) nil)
    (url-recreate-url obj)))

(defun elfeed-show-refresh--mail-style ()
  "Update the buffer to match the selected entry, using a mail-style."
  (interactive)
  (let* ((inhibit-read-only t)
         (title (elfeed-entry-title elfeed-show-entry))
         (date (seconds-to-time (elfeed-entry-date elfeed-show-entry)))
         (author (elfeed-meta elfeed-show-entry :author))
         (link (elfeed-entry-link elfeed-show-entry))
         (tags (elfeed-entry-tags elfeed-show-entry))
         (tagsstr (mapconcat #'symbol-name tags ", "))
         (nicedate (format-time-string "%a, %e %b %Y %T %Z" date))
         (content (elfeed-deref (elfeed-entry-content elfeed-show-entry)))
         (type (elfeed-entry-content-type elfeed-show-entry))
         (feed (elfeed-entry-feed elfeed-show-entry))
         (feed-title (elfeed-feed-title feed))
         (base (and feed (elfeed-compute-base (elfeed-feed-url feed)))))
    (erase-buffer)
    (insert (format (propertize "Title: %s\n" 'face 'message-header-name)
                    (propertize title 'face 'message-header-subject)))
    (when (and author elfeed-show-entry-author)
      (insert (format (propertize "Author: %s\n" 'face 'message-header-name)
                      (propertize author 'face 'message-header-to))) )
    (insert (format (propertize "Date: %s\n" 'face 'message-header-name)
                    (propertize nicedate 'face 'message-header-other)))
    (insert (format (propertize "Feed: %s\n" 'face 'message-header-name)
                    (propertize feed-title 'face 'message-header-other)))
    (when tags
      (insert (format (propertize "Tags: %s\n" 'face 'message-header-name)
                      (propertize tagsstr 'face 'message-header-other))))
    (insert (propertize "Link: " 'face 'message-header-name))
    (elfeed-insert-link link link)
    (insert "\n")
    (cl-loop for enclosure in (elfeed-entry-enclosures elfeed-show-entry)
             do (insert (propertize "Enclosure: " 'face 'message-header-name))
             do (elfeed-insert-link (car enclosure))
             do (insert "\n"))
    (insert "\n")
    (if content
        (if (eq type 'html)
            (elfeed-insert-html content base)
          (insert content))
      (insert (propertize "(empty)\n" 'face 'italic)))
    (goto-char (point-min))))

(defun elfeed-show-refresh ()
  "Update the buffer to match the selected entry."
  (interactive)
  (call-interactively elfeed-show-refresh-function))

(defcustom elfeed-show-unique-buffers nil
  "When non-nil, every entry buffer gets a unique name.
This allows for displaying multiple show buffers at the same
time."
  :group 'elfeed
  :type 'boolean)

(defun elfeed-show--buffer-name (entry)
  "Return the appropriate buffer name for ENTRY.
The result depends on the value of `elfeed-show-unique-buffers'."
  (if elfeed-show-unique-buffers
      (format "*elfeed-entry-<%s %s>*"
	      (elfeed-entry-title entry)
	      (format-time-string "%F" (elfeed-entry-date entry)))
    "*elfeed-entry*"))

(defun elfeed-show-entry (entry)
  "Display ENTRY in the current buffer."
  (let ((buff (get-buffer-create (elfeed-show--buffer-name entry))))
    (with-current-buffer buff
      (elfeed-show-mode)
      (setq elfeed-show-entry entry)
      (elfeed-show-refresh))
    (funcall elfeed-show-entry-switch buff)))

(defun elfeed-show-next ()
  "Show the next item in the elfeed-search buffer."
  (interactive)
  (funcall elfeed-show-entry-delete)
  (with-current-buffer (elfeed-search-buffer)
    (call-interactively #'elfeed-search-show-entry)))

(defun elfeed-show-prev ()
  "Show the previous item in the elfeed-search buffer."
  (interactive)
  (funcall elfeed-show-entry-delete)
  (with-current-buffer (elfeed-search-buffer)
    (forward-line -2)
    (call-interactively #'elfeed-search-show-entry)))

(defun elfeed-show-new-live-search ()
  "Kill the current buffer, search again in *elfeed-search*."
  (interactive)
  (elfeed-kill-buffer)
  (elfeed)
  (elfeed-search-live-filter))

(defun elfeed-show-visit (&optional use-generic-p)
  "Visit the current entry in your browser using `browse-url'.
If there is a prefix argument, visit the current entry in the
browser defined by `browse-url-generic-program'."
  (interactive "P")
  (let ((link (elfeed-entry-link elfeed-show-entry)))
    (when link
      (message "Sent to browser: %s" link)
      (if use-generic-p
          (browse-url-generic link)
        (browse-url link)))))

(defun elfeed-show-yank ()
  "Copy the current entry link URL to the clipboard."
  (interactive)
  (let ((link (elfeed-entry-link elfeed-show-entry)))
    (when link
      (kill-new link)
      (if (fboundp 'gui-set-selection)
          (gui-set-selection 'PRIMARY link)
        (with-no-warnings
          (x-set-selection 'PRIMARY link)))
      (message "Yanked: %s" link))))

(defun elfeed-show-tag (&rest tags)
  "Add TAGS to the displayed entry."
  (interactive (list (intern (read-from-minibuffer "Tag: "))))
  (let ((entry elfeed-show-entry))
    (apply #'elfeed-tag entry tags)
    (with-current-buffer (elfeed-search-buffer)
      (elfeed-search-update-entry entry))
    (elfeed-show-refresh)))

(defun elfeed-show-untag (&rest tags)
  "Remove TAGS from the displayed entry."
  (interactive (let* ((tags (elfeed-entry-tags elfeed-show-entry))
                      (names (mapcar #'symbol-name tags))
                      (select (completing-read "Untag: " names nil :match)))
                 (list (intern select))))
  (let ((entry elfeed-show-entry))
    (apply #'elfeed-untag entry tags)
    (with-current-buffer (elfeed-search-buffer)
      (elfeed-search-update-entry entry))
    (elfeed-show-refresh)))

;; Enclosures:

(defcustom elfeed-enclosure-default-dir (expand-file-name "~")
  "Default directory for saving enclosures.
This can be either a string (a file system path), or a function
that takes a filename and the mime-type as arguments, and returns
the enclosure dir."
  :type 'directory
  :group 'elfeed
  :safe 'stringp)

(defcustom elfeed-save-multiple-enclosures-without-asking nil
  "If non-nil, saving multiple enclosures asks once for a
directory and saves all attachments in the chosen directory."
  :type 'boolean
  :group 'elfeed)

(defvar elfeed-show-enclosure-filename-function
  #'elfeed-show-enclosure-filename-remote
  "Function called to generate the filename for an enclosure.")

(defun elfeed--download-enclosure (url path)
  "Download asynchronously the enclosure from URL to PATH."
  (if (require 'async nil :noerror)
      (with-no-warnings
        (async-start
         (lambda ()
           (url-copy-file url path t))
         (lambda (_)
           (message (format "%s downloaded" url)))))
    (url-copy-file url path t)))

(defun elfeed--get-enclosure-num (prompt entry &optional multi)
  "Ask the user with PROMPT for an enclosure number for ENTRY.
The number is [1..n] for enclosures \[0..(n-1)] in the entry. If
MULTI is nil, return the number for the enclosure;
otherwise (MULTI is non-nil), accept ranges of enclosure numbers,
as per `elfeed-split-ranges-to-numbers', and return the
corresponding string."
  (let* ((count (length (elfeed-entry-enclosures entry)))
         def)
    (when (zerop count)
      (error "No enclosures to this entry"))
    (if (not multi)
        (if (= count 1)
            (read-number (format "%s: " prompt) 1)
          (read-number (format "%s (1-%d): " prompt count)))
      (progn
        (setq def (if (= count 1) "1" (format "1-%d" count)))
        (read-string (format "%s (default %s): " prompt def)
                     nil nil def)))))

(defun elfeed--request-enclosure-path (fname path)
  "Ask the user where to save FNAME (default is PATH/FNAME)."
  (let ((fpath (expand-file-name
                (read-file-name "Save as: " path nil nil fname) path)))
    (if (file-directory-p fpath)
        (expand-file-name fname fpath)
      fpath)))

(defun elfeed--request-enclosures-dir (path)
  "Ask the user where to save multiple enclosures (default is PATH)."
  (let ((fpath (expand-file-name
                (read-directory-name
                 (format "Save in directory: ") path nil nil nil) path)))
    (if (file-directory-p fpath)
        fpath)))

(defun elfeed-show-enclosure-filename-remote (_entry url-enclosure)
  "Returns the remote filename as local filename for an enclosure."
  (file-name-nondirectory
   (url-unhex-string
    (car (url-path-and-query (url-generic-parse-url
                              url-enclosure))))))

(defun elfeed-show-save-enclosure-single (&optional entry enclosure-index)
  "Save enclosure number ENCLOSURE-INDEX from ENTRY.
If ENTRY is nil use the elfeed-show-entry variable.
If ENCLOSURE-INDEX is nil ask for the enclosure number."
  (interactive)
  (let* ((path elfeed-enclosure-default-dir)
         (entry (or entry elfeed-show-entry))
         (enclosure-index (or enclosure-index
                              (elfeed--get-enclosure-num
                               "Enclosure to save" entry)))
         (url-enclosure (car (elt (elfeed-entry-enclosures entry)
                                  (- enclosure-index 1))))
         (fname
          (funcall elfeed-show-enclosure-filename-function
                   entry url-enclosure))
         (retry t)
         (fpath))
    (while retry
      (setf fpath (elfeed--request-enclosure-path fname path)
            retry (and (file-exists-p fpath)
                       (not (y-or-n-p (format "Overwrite '%s'?" fpath))))))
    (elfeed--download-enclosure url-enclosure fpath)))

(defun elfeed-show-save-enclosure-multi (&optional entry)
  "Offer to save multiple entry enclosures from the current entry.
Default is to save all enclosures, [1..n], where n is the number of
enclosures.  You can type multiple values separated by space, e.g.
  1 3-6 8
will save enclosures 1,3,4,5,6 and 8.

Furthermore, there is a shortcut \"a\" which so means all
enclosures, but as this is the default, you may not need it."
  (interactive)
  (let* ((entry (or entry elfeed-show-entry))
         (attachstr (elfeed--get-enclosure-num
                     "Enclosure number range (or 'a' for 'all')" entry t))
         (count (length (elfeed-entry-enclosures entry)))
         (attachnums (elfeed-split-ranges-to-numbers attachstr count))
         (path elfeed-enclosure-default-dir)
         (fpath))
    (if elfeed-save-multiple-enclosures-without-asking
        (let ((attachdir (elfeed--request-enclosures-dir path)))
          (dolist (enclosure-index attachnums)
            (let* ((url-enclosure
                    (aref (elfeed-entry-enclosures entry) enclosure-index))
                   (fname
                    (funcall elfeed-show-enclosure-filename-function
                             entry url-enclosure))
                   (retry t))
              (while retry
                (setf fpath (expand-file-name (concat attachdir fname) path)
                      retry
                      (and (file-exists-p fpath)
                           (not (y-or-n-p (format "Overwrite '%s'?" fpath))))))
              (elfeed--download-enclosure url-enclosure fpath))))
      (dolist (enclosure-index attachnums)
        (elfeed-show-save-enclosure-single entry enclosure-index)))))

(defun elfeed-show-save-enclosure (&optional multi)
  "Offer to save enclosure(s).
If MULTI (prefix-argument) is nil, save a single one, otherwise,
offer to save a range of enclosures."
  (interactive "P")
  (if multi
      (elfeed-show-save-enclosure-multi)
    (elfeed-show-save-enclosure-single)))

(defun elfeed-show-play-enclosure (&optional entry enclosure-index)
  "Play enclosure number ENCLOSURE-INDEX from ENTRY using emms.
If ENTRY is nil use the elfeed-show-entry variable.
If ENCLOSURE-INDEX is nil ask for the enclosure number."
  (interactive)
  (require 'emms) ;; optional
  (let* ((entry (or entry elfeed-show-entry))
         (enclosure-index (or enclosure-index
                              (elfeed--get-enclosure-num
                               "Enclosure to play" entry)))
         (url-enclosure (car (elt (elfeed-entry-enclosures entry)
                                  (- enclosure-index 1)))))
    (with-no-warnings ;; due to lazy (require)
      (with-current-emms-playlist
       (let ((old-pos (point-max)))
         (emms-add-url url-enclosure)
         (goto-char old-pos)
         ;; if we're sitting on a group name, move forward
         (unless (emms-playlist-track-at (point))
           (emms-playlist-next))
         (emms-playlist-select (point)))
       ;; FIXME: is there a better way of doing this?
       (emms-stop)
       (emms-start)))))

(defun elfeed-show-add-enclosure-to-playlist (&optional entry enclosure-index)
  "Play enclosure number ENCLOSURE-INDEX from ENTRY using emms.
If ENTRY is nil use the elfeed-show-entry variable.
If ENCLOSURE-INDEX is nil ask for the enclosure number."
  (interactive)
  (require 'emms) ;; optional
  (let* ((entry (or entry elfeed-show-entry))
         (enclosure-index (or enclosure-index
                              (elfeed--get-enclosure-num
                               "Enclosure to add" entry)))
         (url-enclosure (car (elt (elfeed-entry-enclosures entry)
                                  (- enclosure-index 1)))))
    (with-no-warnings ;; due to lazy (require )
      (emms-add-url url-enclosure))))

(defun elfeed-show-next-link ()
  "Skip to the next link, exclusive of the Link header."
  (interactive)
  (let ((properties (text-properties-at (line-beginning-position))))
    (when (memq 'message-header-name properties)
      (forward-paragraph))
    (shr-next-link)))

(provide 'elfeed-show)

;;; elfeed-show.el ends here
