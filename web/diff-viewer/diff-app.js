// Diff Viewer Application
// Self-contained diff renderer for the cmux DiffPanel.
// Parses unified diff format and renders colored HTML output.

(function () {
    "use strict";

    // State
    var currentUnstaged = [];
    var currentStaged = [];
    var selectedFilePath = null;
    var selectedFileStaged = false;
    var viewMode = "unified"; // "unified" or "split"

    // Section collapse state (persists across updateFileList calls)
    var stagedCollapsed = false;
    var unstagedCollapsed = false;

    // DOM references
    var fileListEl = document.getElementById("file-list");
    var fileCountEl = document.getElementById("file-count");
    var diffContentEl = document.getElementById("diff-content");
    var diffFilenameEl = document.getElementById("diff-filename");
    var toggleViewBtn = document.getElementById("toggle-view");

    // Toggle view mode
    toggleViewBtn.addEventListener("click", function () {
        viewMode = viewMode === "unified" ? "split" : "unified";
        toggleViewBtn.textContent = viewMode === "unified" ? "Unified" : "Side-by-side";
        // Re-render current diff if one is showing
        if (diffContentEl.querySelector(".diff-table")) {
            var rawDiff = diffContentEl.dataset.rawDiff;
            if (rawDiff) {
                renderDiff(rawDiff);
            }
        }
    });

    // Helper to post messages to Swift
    function postMessage(msg) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.diffPanel) {
            window.webkit.messageHandlers.diffPanel.postMessage(msg);
        }
    }

    // --- Public API called from Swift via evaluateJavaScript ---

    /**
     * Update the file list in the sidebar.
     * @param {Object} data - { unstaged: [...], staged: [...] }
     */
    window.updateFileList = function (data) {
        if (Array.isArray(data)) {
            // Backwards compatibility: plain array means unstaged only
            currentUnstaged = data || [];
            currentStaged = [];
        } else {
            currentUnstaged = (data && data.unstaged) || [];
            currentStaged = (data && data.staged) || [];
        }
        renderFileList();
    };

    /**
     * Update the diff view with raw unified diff text.
     * @param {string} diffText - Raw unified diff output from git.
     */
    window.updateFileDiff = function (diffText) {
        if (!diffText || diffText.trim() === "") {
            showPlaceholder("No changes for this file");
            return;
        }
        diffContentEl.dataset.rawDiff = diffText;
        renderDiff(diffText);
    };

    /**
     * Clear all state and reset the viewer.
     */
    window.clearAll = function () {
        currentUnstaged = [];
        currentStaged = [];
        selectedFilePath = null;
        selectedFileStaged = false;
        fileListEl.innerHTML = "";
        fileCountEl.textContent = "0 changed files";
        diffFilenameEl.textContent = "";
        showPlaceholder("Select a file to view changes");
    };

    // --- Rendering ---

    function renderFileList() {
        fileListEl.innerHTML = "";

        var totalCount = currentUnstaged.length + currentStaged.length;

        if (totalCount === 0) {
            fileCountEl.textContent = "0 changed files";
            fileListEl.innerHTML =
                '<div class="no-changes">' +
                '<span class="no-changes-icon">\u2713</span>' +
                "<span>No changes</span>" +
                "</div>";
            return;
        }

        var suffix = totalCount === 1 ? " changed file" : " changed files";
        fileCountEl.textContent = totalCount + suffix;

        // Staged section
        if (currentStaged.length > 0) {
            renderSection(
                "staged",
                "Staged Changes",
                currentStaged,
                true,
                stagedCollapsed
            );
        }

        // Unstaged section
        renderSection(
            "unstaged",
            "Changes",
            currentUnstaged,
            false,
            unstagedCollapsed
        );
    }

    function renderSection(sectionId, title, files, isStaged, isCollapsed) {
        // Section header
        var header = document.createElement("div");
        header.className = "section-header";
        header.dataset.section = sectionId;

        var leftGroup = document.createElement("span");

        var toggle = document.createElement("span");
        toggle.className = "section-toggle";
        toggle.textContent = isCollapsed ? "\u25B8" : "\u25BE";
        leftGroup.appendChild(toggle);

        var titleSpan = document.createElement("span");
        titleSpan.textContent = title + " ";
        leftGroup.appendChild(titleSpan);

        var countSpan = document.createElement("span");
        countSpan.className = "section-count";
        countSpan.textContent = "(" + files.length + ")";
        leftGroup.appendChild(countSpan);

        header.appendChild(leftGroup);

        // Bulk action buttons
        var actions = document.createElement("div");
        actions.className = "section-actions";

        if (isStaged) {
            var unstageAllBtn = document.createElement("button");
            unstageAllBtn.className = "action-btn";
            unstageAllBtn.textContent = "\u2212All";
            unstageAllBtn.title = "Unstage All";
            unstageAllBtn.addEventListener("click", function (e) {
                e.stopPropagation();
                window.unstageAll();
            });
            actions.appendChild(unstageAllBtn);
        } else {
            var stageAllBtn = document.createElement("button");
            stageAllBtn.className = "action-btn";
            stageAllBtn.textContent = "+All";
            stageAllBtn.title = "Stage All";
            stageAllBtn.addEventListener("click", function (e) {
                e.stopPropagation();
                window.stageAll();
            });
            actions.appendChild(stageAllBtn);

            var discardAllBtn = document.createElement("button");
            discardAllBtn.className = "action-btn revert-btn";
            discardAllBtn.textContent = "\u21A9All";
            discardAllBtn.title = "Discard All";
            discardAllBtn.addEventListener("click", function (e) {
                e.stopPropagation();
                window.discardAll();
            });
            actions.appendChild(discardAllBtn);
        }

        header.appendChild(actions);

        // Click header to toggle collapse
        header.addEventListener("click", function () {
            if (sectionId === "staged") {
                stagedCollapsed = !stagedCollapsed;
            } else {
                unstagedCollapsed = !unstagedCollapsed;
            }
            renderFileList();
        });

        fileListEl.appendChild(header);

        // Section content
        var content = document.createElement("div");
        content.className = "section-content";
        if (isCollapsed) {
            content.classList.add("collapsed");
        }

        if (files.length === 0 && !isStaged) {
            var empty = document.createElement("div");
            empty.className = "no-changes";
            empty.style.padding = "12px";
            empty.style.height = "auto";
            var icon = document.createElement("span");
            icon.className = "no-changes-icon";
            icon.style.fontSize = "20px";
            icon.textContent = "\u2713";
            empty.appendChild(icon);
            var msg = document.createElement("span");
            msg.textContent = "No unstaged changes";
            empty.appendChild(msg);
            content.appendChild(empty);
        }

        for (var i = 0; i < files.length; i++) {
            var file = files[i];
            var item = createFileItem(file, isStaged);
            content.appendChild(item);
        }

        fileListEl.appendChild(content);
    }

    function createFileItem(file, isStaged) {
        var item = document.createElement("div");
        item.className = "file-item";
        if (file.path === selectedFilePath && isStaged === selectedFileStaged) {
            item.classList.add("selected");
        }
        item.dataset.path = file.path;
        item.dataset.staged = isStaged ? "true" : "false";

        // Status badge
        var badge = document.createElement("span");
        badge.className = "status-badge status-" + file.status.charAt(0);
        badge.textContent = file.status.charAt(0);
        item.appendChild(badge);

        // File name with directory
        var nameEl = document.createElement("span");
        nameEl.className = "file-name";
        var parts = file.path.split("/");
        if (parts.length > 1) {
            var dirSpan = document.createElement("span");
            dirSpan.className = "file-dir";
            dirSpan.textContent = parts.slice(0, -1).join("/") + "/";
            nameEl.appendChild(dirSpan);
        }
        nameEl.appendChild(document.createTextNode(parts[parts.length - 1]));
        item.appendChild(nameEl);

        // Stats
        if (file.insertions > 0 || file.deletions > 0) {
            var stats = document.createElement("span");
            stats.className = "file-stats";
            if (file.insertions > 0) {
                var addSpan = document.createElement("span");
                addSpan.className = "stat-add";
                addSpan.textContent = "+" + file.insertions;
                stats.appendChild(addSpan);
            }
            if (file.deletions > 0) {
                var delSpan = document.createElement("span");
                delSpan.className = "stat-del";
                delSpan.textContent = "-" + file.deletions;
                stats.appendChild(delSpan);
            }
            item.appendChild(stats);
        }

        // Action buttons
        var actions = document.createElement("div");
        actions.className = "file-actions";

        if (isStaged) {
            // Staged file: unstage button
            var unstageBtn = document.createElement("button");
            unstageBtn.className = "action-btn unstage-btn";
            unstageBtn.textContent = "\u2212";
            unstageBtn.title = "Unstage";
            unstageBtn.dataset.filePath = file.path;
            unstageBtn.addEventListener("click", function (e) {
                e.stopPropagation();
                window.unstageFile(this.dataset.filePath);
            });
            actions.appendChild(unstageBtn);
        } else {
            // Unstaged file: stage + discard buttons
            var stageBtn = document.createElement("button");
            stageBtn.className = "action-btn stage-btn";
            stageBtn.textContent = "+";
            stageBtn.title = "Stage";
            stageBtn.dataset.filePath = file.path;
            stageBtn.addEventListener("click", function (e) {
                e.stopPropagation();
                window.stageFile(this.dataset.filePath);
            });
            actions.appendChild(stageBtn);

            var discardBtn = document.createElement("button");
            discardBtn.className = "action-btn revert-btn";
            discardBtn.textContent = "\u21A9";
            discardBtn.title = "Discard";
            discardBtn.dataset.filePath = file.path;
            discardBtn.addEventListener("click", function (e) {
                e.stopPropagation();
                window.discardFile(this.dataset.filePath);
            });
            actions.appendChild(discardBtn);
        }

        item.appendChild(actions);

        // Click to select file
        item.addEventListener("click", function () {
            var path = this.dataset.path;
            var staged = this.dataset.staged === "true";

            selectedFilePath = path;
            selectedFileStaged = staged;

            // Update selection highlight across all items
            var allItems = fileListEl.querySelectorAll(".file-item");
            for (var j = 0; j < allItems.length; j++) {
                allItems[j].classList.remove("selected");
            }
            this.classList.add("selected");

            // Update toolbar filename
            diffFilenameEl.textContent = path;

            // Show loading state
            diffContentEl.innerHTML =
                '<div id="diff-placeholder">' +
                '<span class="placeholder-text">Loading diff\u2026</span>' +
                "</div>";

            // Request diff from Swift
            postMessage({ action: "selectFile", path: path, staged: staged });
        });

        return item;
    }

    function showPlaceholder(message) {
        diffContentEl.innerHTML =
            '<div id="diff-placeholder">' +
            '<span class="placeholder-icon">&#8644;</span>' +
            '<span class="placeholder-text">' +
            escapeHtml(message) +
            "</span>" +
            "</div>";
    }

    function renderDiff(diffText) {
        var lines = diffText.split("\n");
        var parsedLines = parseDiffLines(lines);

        if (parsedLines.length === 0) {
            showPlaceholder("No diff content");
            return;
        }

        if (viewMode === "split") {
            diffContentEl.innerHTML = renderSplitView(parsedLines);
        } else {
            diffContentEl.innerHTML = renderUnifiedView(parsedLines);
        }

        // Scroll to top
        diffContentEl.scrollTop = 0;
    }

    // --- Diff Parsing ---

    function parseDiffLines(lines) {
        var result = [];
        var oldLine = 0;
        var newLine = 0;

        for (var i = 0; i < lines.length; i++) {
            var line = lines[i];

            // Skip diff header lines
            if (
                line.startsWith("diff --git") ||
                line.startsWith("index ") ||
                line.startsWith("---") ||
                line.startsWith("+++") ||
                line.startsWith("new file mode") ||
                line.startsWith("deleted file mode") ||
                line.startsWith("old mode") ||
                line.startsWith("new mode") ||
                line.startsWith("similarity index") ||
                line.startsWith("rename from") ||
                line.startsWith("rename to") ||
                line.startsWith("Binary files")
            ) {
                continue;
            }

            // Hunk header
            if (line.startsWith("@@")) {
                var hunkMatch = line.match(/@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)/);
                if (hunkMatch) {
                    oldLine = parseInt(hunkMatch[1], 10);
                    newLine = parseInt(hunkMatch[2], 10);
                    result.push({
                        type: "hunk",
                        content: line,
                        oldLine: null,
                        newLine: null,
                    });
                }
                continue;
            }

            // Added line
            if (line.startsWith("+")) {
                result.push({
                    type: "add",
                    content: line.substring(1),
                    oldLine: null,
                    newLine: newLine,
                });
                newLine++;
                continue;
            }

            // Deleted line
            if (line.startsWith("-")) {
                result.push({
                    type: "del",
                    content: line.substring(1),
                    oldLine: oldLine,
                    newLine: null,
                });
                oldLine++;
                continue;
            }

            // Context line (starts with space or is empty within a hunk)
            if (line.startsWith(" ") || (line === "" && result.length > 0)) {
                result.push({
                    type: "context",
                    content: line.startsWith(" ") ? line.substring(1) : line,
                    oldLine: oldLine,
                    newLine: newLine,
                });
                oldLine++;
                newLine++;
            }
        }

        return result;
    }

    // --- Unified View ---

    function renderUnifiedView(parsedLines) {
        var html = '<table class="diff-table unified">' +
            '<colgroup>' +
            '<col style="width:48px">' +
            '<col style="width:48px">' +
            '<col>' +
            '</colgroup>';
        for (var i = 0; i < parsedLines.length; i++) {
            var pline = parsedLines[i];
            html += renderUnifiedLine(pline);
        }
        html += "</table>";
        return html;
    }

    function renderUnifiedLine(pline) {
        var rowClass = "diff-line-" + pline.type;
        var prefix = "";
        var oldNum = pline.oldLine !== null ? pline.oldLine : "";
        var newNum = pline.newLine !== null ? pline.newLine : "";

        switch (pline.type) {
            case "hunk":
                return (
                    '<tr class="' +
                    rowClass +
                    '"><td class="line-number"></td><td class="line-number"></td><td colspan="2">' +
                    escapeHtml(pline.content) +
                    "</td></tr>"
                );
            case "add":
                prefix = "+";
                break;
            case "del":
                prefix = "-";
                break;
            case "context":
                prefix = " ";
                break;
        }

        return (
            '<tr class="' +
            rowClass +
            '">' +
            '<td class="line-number">' +
            oldNum +
            "</td>" +
            '<td class="line-number">' +
            newNum +
            "</td>" +
            '<td class="line-content"><span class="line-prefix">' +
            prefix +
            "</span>" +
            escapeHtml(pline.content) +
            "</td>" +
            "</tr>"
        );
    }

    // --- Side-by-side View ---

    function renderSplitView(parsedLines) {
        // Group consecutive add/del lines into change blocks
        var leftLines = [];
        var rightLines = [];
        var html = '<table class="diff-table side-by-side">' +
            '<colgroup>' +
            '<col style="width:40px">' +
            '<col style="width:calc(50% - 40px)">' +
            '<col style="width:40px">' +
            '<col style="width:calc(50% - 40px)">' +
            '</colgroup>';

        var i = 0;
        while (i < parsedLines.length) {
            var pline = parsedLines[i];

            if (pline.type === "hunk") {
                // Flush pending
                html += flushSplitPairs(leftLines, rightLines);
                leftLines = [];
                rightLines = [];
                html +=
                    '<tr class="diff-line-hunk"><td colspan="2" class="side-left">' +
                    escapeHtml(pline.content) +
                    '</td><td colspan="2" class="side-right">' +
                    escapeHtml(pline.content) +
                    "</td></tr>";
                i++;
                continue;
            }

            if (pline.type === "context") {
                html += flushSplitPairs(leftLines, rightLines);
                leftLines = [];
                rightLines = [];
                html +=
                    '<tr class="diff-line-context">' +
                    '<td class="line-number">' +
                    (pline.oldLine || "") +
                    "</td>" +
                    '<td class="line-content side-left">' +
                    escapeHtml(pline.content) +
                    "</td>" +
                    '<td class="line-number">' +
                    (pline.newLine || "") +
                    "</td>" +
                    '<td class="line-content side-right">' +
                    escapeHtml(pline.content) +
                    "</td>" +
                    "</tr>";
                i++;
                continue;
            }

            if (pline.type === "del") {
                leftLines.push(pline);
                i++;
                continue;
            }

            if (pline.type === "add") {
                rightLines.push(pline);
                i++;
                continue;
            }

            i++;
        }

        html += flushSplitPairs(leftLines, rightLines);
        html += "</table>";
        return html;
    }

    function flushSplitPairs(leftLines, rightLines) {
        if (leftLines.length === 0 && rightLines.length === 0) return "";

        var html = "";
        var maxLen = Math.max(leftLines.length, rightLines.length);

        for (var j = 0; j < maxLen; j++) {
            var left = j < leftLines.length ? leftLines[j] : null;
            var right = j < rightLines.length ? rightLines[j] : null;

            html += "<tr>";

            // Left side (deletions)
            if (left) {
                html +=
                    '<td class="line-number">' +
                    (left.oldLine || "") +
                    "</td>" +
                    '<td class="line-content side-left diff-line-del"><span class="line-prefix">-</span>' +
                    escapeHtml(left.content) +
                    "</td>";
            } else {
                html += '<td class="line-number"></td><td class="line-content side-left"></td>';
            }

            // Right side (additions)
            if (right) {
                html +=
                    '<td class="line-number">' +
                    (right.newLine || "") +
                    "</td>" +
                    '<td class="line-content side-right diff-line-add"><span class="line-prefix">+</span>' +
                    escapeHtml(right.content) +
                    "</td>";
            } else {
                html += '<td class="line-number"></td><td class="line-content side-right"></td>';
            }

            html += "</tr>";
        }

        return html;
    }

    // --- Utilities ---

    function escapeHtml(text) {
        if (!text) return "";
        return text
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;");
    }

    // --- Git Actions ---

    window.stageFile = function (path) {
        postMessage({ action: "stageFile", path: path });
    };

    window.unstageFile = function (path) {
        postMessage({ action: "unstageFile", path: path });
    };

    window.unstageAll = function () {
        postMessage({ action: "unstageAll" });
    };

    window.discardFile = function (path) {
        if (confirm("Discard changes to " + path + "?")) {
            postMessage({ action: "revertFile", path: path });
        }
    };

    window.stageAll = function () {
        postMessage({ action: "stageAll" });
    };

    window.discardAll = function () {
        if (confirm("Discard ALL changes? This cannot be undone.")) {
            postMessage({ action: "revertAll" });
        }
    };

    // Keep backwards compat aliases
    window.revertFile = window.discardFile;
    window.revertAll = window.discardAll;

    // --- Resizable divider ---
    (function () {
        var divider = document.getElementById("divider");
        var fileTree = document.getElementById("file-tree");
        var isDragging = false;

        divider.addEventListener("mousedown", function (e) {
            isDragging = true;
            divider.classList.add("dragging");
            document.body.style.cursor = "col-resize";
            document.body.style.userSelect = "none";
            e.preventDefault();
        });

        document.addEventListener("mousemove", function (e) {
            if (!isDragging) return;
            var newWidth = Math.max(150, Math.min(500, e.clientX));
            fileTree.style.width = newWidth + "px";
        });

        document.addEventListener("mouseup", function () {
            if (!isDragging) return;
            isDragging = false;
            divider.classList.remove("dragging");
            document.body.style.cursor = "";
            document.body.style.userSelect = "";
        });
    })();

    // Notify Swift that the page is ready
    postMessage({ action: "ready" });
})();
