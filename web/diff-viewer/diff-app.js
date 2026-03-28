// Diff Viewer Application
// Self-contained diff renderer for the cmux DiffPanel.
// Parses unified diff format and renders colored HTML output.

(function () {
    "use strict";

    // State
    let currentFiles = [];
    let selectedFilePath = null;
    let viewMode = "unified"; // "unified" or "split"

    // DOM references
    const fileListEl = document.getElementById("file-list");
    const fileCountEl = document.getElementById("file-count");
    const diffContentEl = document.getElementById("diff-content");
    const diffFilenameEl = document.getElementById("diff-filename");
    const toggleViewBtn = document.getElementById("toggle-view");

    // Toggle view mode
    toggleViewBtn.addEventListener("click", function () {
        viewMode = viewMode === "unified" ? "split" : "unified";
        toggleViewBtn.textContent = viewMode === "unified" ? "Unified" : "Side-by-side";
        // Re-render current diff if one is showing
        if (diffContentEl.querySelector(".diff-table")) {
            const rawDiff = diffContentEl.dataset.rawDiff;
            if (rawDiff) {
                renderDiff(rawDiff);
            }
        }
    });

    // --- Public API called from Swift via evaluateJavaScript ---

    /**
     * Update the file list in the sidebar.
     * @param {Array<{path: string, status: string, insertions: number, deletions: number}>} files
     */
    window.updateFileList = function (files) {
        currentFiles = files || [];
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
        currentFiles = [];
        selectedFilePath = null;
        fileListEl.innerHTML = "";
        fileCountEl.textContent = "0 changed files";
        diffFilenameEl.textContent = "";
        showPlaceholder("Select a file to view changes");
    };

    // --- Rendering ---

    function renderFileList() {
        fileListEl.innerHTML = "";

        if (currentFiles.length === 0) {
            fileCountEl.textContent = "0 changed files";
            fileListEl.innerHTML =
                '<div class="no-changes">' +
                '<span class="no-changes-icon">\u2713</span>' +
                "<span>No unstaged changes</span>" +
                "</div>";
            return;
        }

        var suffix = currentFiles.length === 1 ? " changed file" : " changed files";
        fileCountEl.textContent = currentFiles.length + suffix;

        for (var i = 0; i < currentFiles.length; i++) {
            var file = currentFiles[i];
            var item = document.createElement("div");
            item.className = "file-item";
            if (file.path === selectedFilePath) {
                item.classList.add("selected");
            }
            item.dataset.path = file.path;

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

            item.addEventListener("click", onFileClick);
            fileListEl.appendChild(item);
        }
    }

    function onFileClick(event) {
        var item = event.currentTarget;
        var path = item.dataset.path;

        // Update selection
        selectedFilePath = path;
        var items = fileListEl.querySelectorAll(".file-item");
        for (var j = 0; j < items.length; j++) {
            items[j].classList.remove("selected");
        }
        item.classList.add("selected");

        // Update toolbar filename
        diffFilenameEl.textContent = path;

        // Show loading state
        diffContentEl.innerHTML =
            '<div id="diff-placeholder">' +
            '<span class="placeholder-text">Loading diff\u2026</span>' +
            "</div>";

        // Request diff from Swift
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.diffPanel) {
            window.webkit.messageHandlers.diffPanel.postMessage({
                action: "selectFile",
                path: path,
            });
        }
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
        var html = '<table class="diff-table unified">';
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
        var html = '<table class="diff-table side-by-side">';

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

    // Notify Swift that the page is ready
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.diffPanel) {
        window.webkit.messageHandlers.diffPanel.postMessage({ action: "ready" });
    }
})();
