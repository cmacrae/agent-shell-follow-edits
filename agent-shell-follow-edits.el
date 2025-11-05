;;; agent-shell-follow-edits.el --- Automatically follow agent edits in agent-shell -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Calum MacRae

;; Author: Calum MacRae
;; URL: https://github.com/cmacrae/agent-shell-follow-edits
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.17.2"))

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; This package provides automatic file following functionality for agent-shell.
;; When enabled, files being edited by the agent are automatically displayed
;; in another window, allowing you to see changes as they happen without
;; disrupting your current workflow.
;;
;; Usage:
;;   (require 'agent-shell-follow-edits)
;;   (agent-shell-follow-edits-mode 1)
;;
;; You can also toggle on the fly:
;;   M-x agent-shell-follow-edits-toggle

;;; Code:

(require 'pulse)
(require 'map)

;; Declare agent-shell functions and variables we'll use
(declare-function agent-shell--resolve-path "agent-shell")
(defvar agent-shell-tool-call-update-functions)
(defvar agent-shell-permission-request-functions)
(defvar agent-shell-file-write-functions)

(defgroup agent-shell-follow-edits nil
  "Automatically follow agent edits in agent-shell."
  :group 'agent-shell
  :prefix "agent-shell-follow-edits-")

(defcustom agent-shell-follow-edits-enabled nil
  "Whether to automatically display files that the agent is editing.

When non-nil, Emacs will automatically display files being modified
by the agent in another window, allowing you to see changes as they
happen without disrupting your current workflow."
  :type 'boolean
  :group 'agent-shell-follow-edits)

(defcustom agent-shell-follow-edits-delay 0.3
  "Delay in seconds before following to a file being edited.

This prevents rapid buffer switching when the agent makes multiple
quick edits.  Set to 0 for immediate following."
  :type 'number
  :group 'agent-shell-follow-edits)

(defcustom agent-shell-follow-edits-highlight t
  "Whether to highlight text that the agent has just edited.

When non-nil and `agent-shell-follow-edits-enabled' is enabled, edited regions
will pulse slowly using Emacs' built-in pulse effect to make it clear
what changed."
  :type 'boolean
  :group 'agent-shell-follow-edits)

(defcustom agent-shell-follow-edits-highlight-face 'lazy-highlight
  "Face to use for highlighting agent edits after they are accepted.

This should be a face symbol that has a :background attribute, as the
pulsing effect works by creating a gradient from the face's background
color to the default background color.

Good choices:
- `lazy-highlight' - Cyan/turquoise search highlighting (default)
- `region' - Your selection color
- `secondary-selection' - Alternative highlight color
- `pulse-highlight-start-face' - Yellow pulse highlighting

NOTE: The face MUST have a :background attribute for pulsing to be
visible. Faces that only have foreground colors or other attributes
will not work."
  :type 'face
  :group 'agent-shell-follow-edits)

(defface agent-shell-follow-edits-diff-removed-face
  '((t (:inherit diff-refine-removed)))
  "Face for removed lines in permission preview diffs.
By default, inherits from `diff-refine-removed', Emacs' built-in face
for highlighting removed text in diffs.

If you have magit installed and prefer its style, customise this to inherit:

  (custom-set-faces
   \\='(agent-shell-follow-edits-diff-removed-face
     ((t (:inherit magit-diff-removed-highlight)))))

NOTE: If you customise this face to inherit from a lazily-loaded package
\(like magit), ensure that package is loaded before agent-shell displays
diffs, or the face will appear unstyled. You can do this by requiring the
package in your init file, or by using it before starting an agent session.

Alternative faces to consider:
- `diff-refine-removed' - Emacs built-in refined removed face (default)
- `diff-removed' - Standard diff removed face (less prominent)
- `magit-diff-removed' - Magit's removed line face
- `magit-diff-removed-highlight' - Magit's highlighted removed face"
  :group 'agent-shell-follow-edits)

(defface agent-shell-follow-edits-diff-added-face
  '((t (:inherit diff-refine-added)))
  "Face for added lines in permission preview diffs.
By default, inherits from `diff-refine-added', Emacs' built-in face
for highlighting added text in diffs.

If you have magit installed and prefer its style, customise this to inherit:

  (custom-set-faces
   \\='(agent-shell-follow-edits-diff-added-face
     ((t (:inherit magit-diff-added-highlight)))))

NOTE: If you customise this face to inherit from a lazily-loaded package
\(like magit), ensure that package is loaded before agent-shell displays
diffs, or the face will appear unstyled. You can do this by requiring the
package in your init file, or by using it before starting an agent session.

Alternative faces to consider:
- `diff-refine-added' - Emacs built-in refined added face (default)
- `diff-added' - Standard diff added face (less prominent)
- `magit-diff-added' - Magit's added line face
- `magit-diff-added-highlight' - Magit's highlighted added face"
  :group 'agent-shell-follow-edits)

;;; Buffer-local state

(defvar-local agent-shell-follow-edits--timer nil
  "Timer for debouncing follow-to-location calls.")

(defvar-local agent-shell-follow-edits--permission-preview-state nil
  "Alist mapping tool-call-id to preview state.
Each entry is (tool-call-id . plist) where plist contains:
  :buffer - buffer showing the preview
  :overlays - list of overlay objects
  :old-start - start position of old text
  :old-end - end position of old text
  :changed-start - start position of changed region
  :changed-end - end position of changed region
  :new-changed - the new text that will replace the old
  :path - file path")

;;; Helper Functions

(defun agent-shell-follow-edits--compute-edit-region (old-text new-text)
  "Compute the actual changed region between OLD-TEXT and NEW-TEXT.
Returns a cons cell (UNCHANGED-PREFIX-LEN . CHANGED-NEW-TEXT) or nil."
  (when (and old-text new-text)
    (let* ((old-len (length old-text))
           (new-len (length new-text))
           (min-len (min old-len new-len))
           ;; Find common prefix using compare-strings with binary search
           (prefix-len 0))
      ;; Binary search for longest common prefix
      (let ((low 0)
            (high min-len))
        (while (< low high)
          (let ((mid (ceiling (/ (+ low high 1.0) 2))))
            (if (eq t (compare-strings old-text 0 mid new-text 0 mid))
                (setq low mid)  ; mid matches, try higher
              (setq high (1- mid)))))  ; mid doesn't match, try lower
        (setq prefix-len low))

      ;; Find common suffix
      (let ((suffix-len 0)
            (max-suffix (- min-len prefix-len)))
        (while (and (< suffix-len max-suffix)
                    (eq (aref old-text (- old-len suffix-len 1))
                        (aref new-text (- new-len suffix-len 1))))
          (setq suffix-len (1+ suffix-len)))

        ;; Extract the changed portion of new-text
        (let ((changed-text (substring new-text prefix-len (- new-len suffix-len))))
          (cons prefix-len changed-text))))))

(defun agent-shell-follow-edits--extract-changed-region (old-text new-text)
  "Extract just the changed region from OLD-TEXT and NEW-TEXT.
Returns a plist with :prefix-lines, :old-changed, :new-changed,
:old-changed-lines, and :new-changed-lines.
If texts are very different, returns the full texts."
  (let* ((old-lines (split-string old-text "\n"))
         (new-lines (split-string new-text "\n"))
         (old-len (length old-lines))
         (new-len (length new-lines))
         ;; Find common prefix
         (prefix-len 0)
         ;; Find common suffix
         (suffix-len 0))

    ;; Count matching lines from the start
    (while (and (< prefix-len old-len)
                (< prefix-len new-len)
                (string= (nth prefix-len old-lines)
                         (nth prefix-len new-lines)))
      (setq prefix-len (1+ prefix-len)))

    ;; Count matching lines from the end
    (while (and (< suffix-len (- old-len prefix-len))
                (< suffix-len (- new-len prefix-len))
                (string= (nth (- old-len suffix-len 1) old-lines)
                         (nth (- new-len suffix-len 1) new-lines)))
      (setq suffix-len (1+ suffix-len)))

    ;; Extract the changed middle part
    (let* ((old-changed-lines (seq-subseq old-lines prefix-len (- old-len suffix-len)))
           (new-changed-lines (seq-subseq new-lines prefix-len (- new-len suffix-len)))
           (old-changed (string-join old-changed-lines "\n"))
           (new-changed (string-join new-changed-lines "\n")))

      ;; Return the changed portions and metadata
      (list :prefix-lines prefix-len
            :old-changed old-changed
            :new-changed new-changed
            :old-changed-lines (length old-changed-lines)
            :new-changed-lines (length new-changed-lines)))))

(defun agent-shell-follow-edits--position-window-at-change (window buffer position)
  "Position WINDOW showing BUFFER at POSITION."
  (when (and (window-live-p window)
             (buffer-live-p buffer))
    ;; Calculate window-start to center the position in the window
    ;; and immediately position using set-window-start
    (let ((target-start (with-current-buffer buffer
                          (save-excursion
                            (goto-char position)
                            ;; Use max to ensure we don't try to scroll before buffer start
                            (let* ((lines-before (/ (window-height window) 2))
                                   (current-line (line-number-at-pos))
                                   ;; Can't go back more lines than exist
                                   (lines-to-move (min lines-before (1- current-line))))
                              (forward-line (- lines-to-move))
                              ;; Ensure we're not at point-min unless position is there
                              (max (point-min) (point)))))))
      (set-window-start window target-start t)  ; t = force redisplay
      (set-window-point window position))

    ;; Verify and re-apply after initial redisplay
    (run-at-time
     0.05 nil
     (lambda ()
       (when (and (window-live-p window)
                  (buffer-live-p buffer))
         (let ((target-start (with-current-buffer buffer
                               (save-excursion
                                 (goto-char position)
                                 (let* ((lines-before (/ (window-height window) 2))
                                        (current-line (line-number-at-pos))
                                        (lines-to-move (min lines-before (1- current-line))))
                                   (forward-line (- lines-to-move))
                                   (max (point-min) (point)))))))
           (set-window-start window target-start t)
           (set-window-point window position)))))

    ;; Final verification after all redisplay completes
    (run-at-time
     0.15 nil
     (lambda ()
       (when (and (window-live-p window)
                  (buffer-live-p buffer))
         (let ((target-start (with-current-buffer buffer
                               (save-excursion
                                 (goto-char position)
                                 (let* ((lines-before (/ (window-height window) 2))
                                        (current-line (line-number-at-pos))
                                        (lines-to-move (min lines-before (1- current-line))))
                                   (forward-line (- lines-to-move))
                                   (max (point-min) (point)))))))
           (set-window-start window target-start t)
           (set-window-point window position)))))))

(defun agent-shell-follow-edits--follow-to-location (location &optional diff-info)
  "Visit the file and position specified by LOCATION.

LOCATION is an alist with \\='path and optional \\='line keys.
DIFF-INFO is an optional alist with :old, :new, and :file keys.
Respects `agent-shell-follow-edits-enabled' setting."
  (when agent-shell-follow-edits-enabled
    (let ((raw-path (map-elt location 'path)))
      (when-let* ((path (agent-shell--resolve-path raw-path)))
        (let ((buffer (or (find-buffer-visiting path)
                          (find-file-noselect path)))
              (line (map-elt location 'line))
              (old-text (map-elt diff-info :old))
              (new-text (map-elt diff-info :new)))
          (when buffer
            ;; Display buffer in another window without selecting it
            (let ((window (display-buffer buffer)))
              (when window
                (with-current-buffer buffer
                  (let ((target-pos
                         (cond
                          ;; First: Use ACP-provided line number
                          ((and line (numberp line))
                           (save-excursion
                             (goto-char (point-min))
                             (forward-line line)
                             (point)))
                          ;; Fallback: Search for old text if no line number
                          ((and old-text new-text)
                           (save-excursion
                             (goto-char (point-min))
                             (if (search-forward old-text nil t)
                                 (match-beginning 0)
                               ;; Search failed: stay at current point
                               (point))))
                          ;; Last resort: Don't move, stay at current point
                          (t (point)))))
                    ;; Position window without selecting it
                    (agent-shell-follow-edits--position-window-at-change window buffer target-pos)))))))))))

(defun agent-shell-follow-edits--format-diff-preview (old-text new-text)
  "Format OLD-TEXT and NEW-TEXT as a colorized unified diff.
Returns a propertized string showing deletions and additions."
  (let* ((old-lines (split-string old-text "\n"))
         (new-lines (split-string new-text "\n"))
         (result '()))
    ;; Add deleted lines
    (dolist (line old-lines)
      (push (propertize (concat "-" line)
                        'face 'agent-shell-follow-edits-diff-removed-face)
            result))
    ;; Add new lines
    (dolist (line new-lines)
      (push (propertize (concat "+" line)
                        'face 'agent-shell-follow-edits-diff-added-face)
            result))
    ;; Return in correct order with newlines
    (string-join (nreverse result) "\n")))

(defun agent-shell-follow-edits--search-for-text-with-strategies (text acp-line-hint)
  "Search for TEXT using multiple strategies, prioritizing ACP-LINE-HINT.
Returns the match position or nil if not found."
  (let ((match-pos nil))
    (save-excursion
      ;; Strategy 1: Search near ACP-provided line (±50 lines)
      (when (and acp-line-hint (numberp acp-line-hint) (not match-pos))
        (goto-char (point-min))
        (forward-line acp-line-hint)
        (let ((search-start (save-excursion (forward-line -50) (point)))
              (search-end (save-excursion (forward-line 100) (point))))
          (goto-char search-start)
          (when (search-forward text search-end t)
            (setq match-pos (match-beginning 0)))))
      ;; Strategy 2: Forward from ACP line
      (when (and acp-line-hint (numberp acp-line-hint) (not match-pos))
        (goto-char (point-min))
        (forward-line acp-line-hint)
        (when (search-forward text nil t)
          (setq match-pos (match-beginning 0))))
      ;; Strategy 3: Backward from ACP line
      (when (and acp-line-hint (numberp acp-line-hint) (not match-pos))
        (goto-char (point-min))
        (forward-line acp-line-hint)
        (when (search-backward text nil t)
          (setq match-pos (match-beginning 0))))
      ;; Strategy 4: Full buffer search
      (when (not match-pos)
        (goto-char (point-min))
        (when (search-forward text nil t)
          (setq match-pos (match-beginning 0))))
      match-pos)))

(defun agent-shell-follow-edits--create-permission-preview (tool-call-id diff-info location agent-shell-buffer)
  "Show preview of changes for TOOL-CALL-ID using a colorized unified diff.
DIFF-INFO is a plist with :old, :new, and :file keys.
LOCATION is an alist with 'path and optional 'line keys.
AGENT-SHELL-BUFFER is the agent-shell buffer for storing state."
  (when (and agent-shell-follow-edits-enabled diff-info location)
    (let* ((path (agent-shell-resolve-path (map-elt location 'path)))
           (old-text (plist-get diff-info :old))
           (new-text (plist-get diff-info :new))
           (line (map-elt location 'line)))
      (when (and path old-text new-text)
        (let ((buffer (or (find-buffer-visiting path)
                          (find-file-noselect path))))
          (when buffer
            (with-current-buffer buffer
              (let ((inhibit-read-only t))
                (save-excursion
                  (goto-char (point-min))
                  (when line (forward-line line))
                  (let* ((change-info (agent-shell-follow-edits--extract-changed-region old-text new-text))
                         (prefix-lines (plist-get change-info :prefix-lines))
                         (old-changed (plist-get change-info :old-changed))
                         (new-changed (plist-get change-info :new-changed))
                         (old-changed-lines (plist-get change-info :old-changed-lines)))
                    (let ((match-pos (agent-shell-follow-edits--search-for-text-with-strategies old-text line)))
                      (when match-pos
                        (let* ((old-start match-pos)
                               (old-end (+ match-pos (length old-text)))
                               (changed-start (save-excursion
                                                (goto-char old-start)
                                                (forward-line prefix-lines)
                                                (point)))
                               (changed-end-raw (save-excursion
                                                  (goto-char changed-start)
                                                  (forward-line old-changed-lines)
                                                  (point)))
                               (changed-end (if (= changed-start changed-end-raw)
                                                (save-excursion
                                                  (goto-char changed-start)
                                                  (if (and (eolp) (= (point) (point-max)))
                                                      (progn (insert "\n") (point))
                                                    (if (eolp)
                                                        (min (point-max) (1+ (point)))
                                                      (min (point-max) (1+ (point))))))
                                              changed-end-raw))
                               (window (or (get-buffer-window buffer)
                                           (display-buffer buffer)))
                               (diff-preview (agent-shell-follow-edits--format-diff-preview old-changed new-changed)))
                          ;; Position window before creating overlay
                          (when window
                            (agent-shell-follow-edits--position-window-at-change window buffer changed-start))
                          ;; Create overlay
                          (let ((ov (make-overlay changed-start changed-end buffer t nil)))
                            (overlay-put ov 'face 'default)
                            (overlay-put ov 'priority 100)
                            (overlay-put ov 'display diff-preview)
                            (overlay-put ov 'agent-shell-permission-preview t)
                            ;; Store preview state in agent-shell buffer
                            (with-current-buffer agent-shell-buffer
                              (setf (alist-get tool-call-id agent-shell-follow-edits--permission-preview-state nil nil #'equal)
                                    (list :buffer buffer
                                          :overlays (list ov)
                                          :old-start old-start
                                          :old-end old-end
                                          :changed-start changed-start
                                          :changed-end changed-end
                                          :new-changed new-changed
                                          :path path)))
                            buffer)))))))))))))

(defun agent-shell-follow-edits--remove-permission-preview (tool-call-id agent-shell-buffer)
  "Remove permission preview for TOOL-CALL-ID in AGENT-SHELL-BUFFER."
  (with-current-buffer agent-shell-buffer
    (when-let ((preview-state (alist-get tool-call-id agent-shell-follow-edits--permission-preview-state nil nil #'equal)))
      (let ((overlays (plist-get preview-state :overlays))
            (buffer (plist-get preview-state :buffer))
            (changed-start (plist-get preview-state :changed-start))
            (changed-end (plist-get preview-state :changed-end)))
        (dolist (ov overlays)
          (when (overlayp ov)
            (delete-overlay ov)))
        ;; Remove temporary newline if inserted at EOF
        (when (and buffer (buffer-live-p buffer) changed-start changed-end)
          (with-current-buffer buffer
            (let ((inhibit-read-only t))
              (save-excursion
                (goto-char changed-start)
                (when (and (= changed-end (1+ changed-start))
                           (= changed-end (point-max))
                           (looking-at "\n\\'"))
                  (delete-char 1)))))))
      (setf (alist-get tool-call-id agent-shell-follow-edits--permission-preview-state nil t #'equal) nil))))

;;; Hook Handlers

(defun agent-shell-follow-edits--on-tool-call-update (state update)
  "Handle tool call updates to follow edits.
Called with STATE and UPDATE from agent-shell."
  (when agent-shell-follow-edits-enabled
    (let-alist update
      (when .toolCallId
        (let ((agent-shell-buffer (current-buffer)))
          ;; Only follow when status becomes "in_progress"
          (when (equal .status "in_progress")
          ;; Get the stored tool call from state
          (when-let* ((tool-call (map-nested-elt state `(:tool-calls ,.toolCallId)))
                    (kind (map-elt tool-call :kind))
                    (locations (map-elt tool-call :locations)))
          (when (and kind
                     (memq (intern kind) '(edit write))
                     locations)
            (let* ((location (if (vectorp locations)
                                 (and (> (length locations) 0)
                                      (aref locations 0))
                               (car locations)))
                   (diff-info (map-elt tool-call :diff))
                   (source-buffer (current-buffer)))
              (when location
                ;; Cancel any existing timer
                (when agent-shell-follow-edits--timer
                  (cancel-timer agent-shell-follow-edits--timer))
                ;; Set new timer with debounce delay
                (setq agent-shell-follow-edits--timer
                      (run-with-timer
                       agent-shell-follow-edits-delay
                       nil
                       (lambda ()
                         (when (buffer-live-p source-buffer)
                           (with-current-buffer source-buffer
                             (agent-shell-follow-edits--follow-to-location location diff-info)))))))))))))))))

(defun agent-shell-follow-edits--on-permission-request (state request)
  "Handle permission requests to show diff preview.
Called with STATE and REQUEST from agent-shell.
Returns t to prevent default handling (we'll show our own preview)."
  (when agent-shell-follow-edits-enabled
    (let-alist request
      (when (and .params.toolCall.toolCallId
                 .params.toolCall.rawInput)
        (let ((tool-call-id .params.toolCall.toolCallId)
              (agent-shell-buffer (current-buffer)))
          (let-alist .params.toolCall.rawInput
            (when (and .file_path .old_string .new_string)
              (let ((diff-info (list :old .old_string :new .new_string :file .file_path))
                    (location (list (cons 'path .file_path))))
                ;; Create preview - wrapped in condition-case to ensure dialog shows even if preview fails
                (condition-case err
                    (agent-shell-follow-edits--create-permission-preview
                     tool-call-id diff-info location agent-shell-buffer)
                  (error
                   (message "Failed to create permission preview: %s" (error-message-string err))))))))))
  ;; Return nil to allow default permission handling
  ;; The preview is supplementary - agent-shell still shows the permission dialog
  nil))

(defun agent-shell-follow-edits--on-permission-response (_state _request-id tool-call-id _option-id _cancelled)
  "Handle permission responses to clean up preview.
Called with STATE, REQUEST-ID, TOOL-CALL-ID, OPTION-ID, and CANCELLED from agent-shell.
Always cleans up preview overlay regardless of accept/reject."
  (when agent-shell-follow-edits-enabled
    (let ((agent-shell-buffer (current-buffer)))
      ;; Always clean up preview when permission is resolved
      (agent-shell-follow-edits--remove-permission-preview tool-call-id agent-shell-buffer))))

(defun agent-shell-follow-edits--on-file-write (state path _content tool-call-id)
  "Handle file writes to highlight changes.
Called with STATE, PATH, CONTENT, and TOOL-CALL-ID from agent-shell."
  (when (and agent-shell-follow-edits-enabled
             agent-shell-follow-edits-highlight
             tool-call-id)
    (when-let* ((buffer (find-buffer-visiting path))
                (tool-call (map-nested-elt state `(:tool-calls ,tool-call-id)))
                (raw-input (map-elt tool-call :rawInput)))
      (let-alist raw-input
        (when (and .old_string .new_string)
          ;; Search for the new_string in the buffer
          (with-current-buffer buffer
            (let ((found-pos (save-excursion
                               (goto-char (point-min))
                               (when (search-forward .new_string nil t)
                                 (match-beginning 0)))))
              (when found-pos
                ;; Compute where the changed portion is within new_string
                (if-let* ((edit-info (agent-shell-follow-edits--compute-edit-region .old_string .new_string)))
                    (let* ((prefix-len (car edit-info))
                           (changed-text (cdr edit-info))
                           ;; Position of changed portion in buffer
                           (changed-start (+ found-pos prefix-len))
                           (changed-end (+ changed-start (length changed-text)))
                           (window (get-buffer-window buffer)))
                      ;; Position window and cursor at the changed portion
                      (goto-char changed-start)
                      (when window
                        (set-window-point window changed-start)
                        (with-selected-window window
                          (recenter)))
                      ;; Pulse highlight the changed portion
                      (let ((pulse-flag t)
                            (pulse-delay 0.1)
                            (pulse-iterations 50))
                        (pulse-momentary-highlight-region changed-start changed-end agent-shell-follow-edits-highlight-face)))
                  ;; Fallback: highlight entire new_string if compute fails
                  (let* ((new-start found-pos)
                         (new-end (+ found-pos (length .new_string)))
                         (window (get-buffer-window buffer)))
                    ;; Position window
                    (goto-char new-start)
                    (when window
                      (set-window-point window new-start)
                      (with-selected-window window
                        (recenter)))
                    ;; Pulse highlight the entire new string
                    (let ((pulse-flag t)
                          (pulse-delay 0.1)
                          (pulse-iterations 50))
                      (pulse-momentary-highlight-region new-start new-end agent-shell-follow-edits-highlight-face))))))))))))

;;; Interactive Commands

;;;###autoload
(defun agent-shell-follow-edits-toggle ()
  "Toggle automatic following of agent edits.

When enabled, files being edited by the agent are automatically
displayed in another window without disrupting your workflow."
  (interactive)
  (setq agent-shell-follow-edits-enabled (not agent-shell-follow-edits-enabled))
  (message "Follow edits: %s" (if agent-shell-follow-edits-enabled "ON" "OFF")))

;;;###autoload
(define-minor-mode agent-shell-follow-edits-mode
  "Minor mode for automatically following agent edits in agent-shell.

When enabled, this mode hooks into agent-shell to automatically display
files being edited by the agent in another window, and optionally
highlights the changes with a pulse effect.

The mode adds handlers to agent-shell's extension hooks:
- `agent-shell-tool-call-update-functions' - to follow file edits
- `agent-shell-file-write-functions' - to highlight changes

You can customise the behavior with:
- `agent-shell-follow-edits-delay' - delay before following
- `agent-shell-follow-edits-highlight' - whether to highlight changes
- `agent-shell-follow-edits-highlight-face' - face used for highlighting
- `agent-shell-follow-edits-diff-removed-face' - face for removed text in diffs
- `agent-shell-follow-edits-diff-added-face' - face for added text in diffs"
  :global t
  :lighter " Follow"
  :group 'agent-shell-follow-edits
  (if agent-shell-follow-edits-mode
      (progn
        ;; Enable the feature
        (setq agent-shell-follow-edits-enabled t)
        ;; Disable View button since we show inline preview
        (setq agent-shell-show-permission-diff-button nil)
        ;; Add our hook handlers
        (add-hook 'agent-shell-tool-call-update-functions
                  #'agent-shell-follow-edits--on-tool-call-update)
        (add-hook 'agent-shell-permission-request-functions
                  #'agent-shell-follow-edits--on-permission-request)
        (add-hook 'agent-shell-permission-response-functions
                  #'agent-shell-follow-edits--on-permission-response)
        (add-hook 'agent-shell-file-write-functions
                  #'agent-shell-follow-edits--on-file-write)
        (message "Agent shell follow edits mode enabled"))
    ;; Disable the feature
    (setq agent-shell-follow-edits-enabled nil)
    ;; Re-enable View button
    (setq agent-shell-show-permission-diff-button t)
    ;; Remove our hook handlers
    (remove-hook 'agent-shell-tool-call-update-functions
                 #'agent-shell-follow-edits--on-tool-call-update)
    (remove-hook 'agent-shell-permission-request-functions
                 #'agent-shell-follow-edits--on-permission-request)
    (remove-hook 'agent-shell-permission-response-functions
                 #'agent-shell-follow-edits--on-permission-response)
    (remove-hook 'agent-shell-file-write-functions
                 #'agent-shell-follow-edits--on-file-write)
    (message "Agent shell follow edits mode disabled")))

(provide 'agent-shell-follow-edits)
;;; agent-shell-follow-edits.el ends here
