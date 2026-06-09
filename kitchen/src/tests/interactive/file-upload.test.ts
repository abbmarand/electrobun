// Interactive File Upload / File Picker Parity Tests
//
// These tests host a tiny localhost diagnostic page and load it in a window so
// manual QA can verify <input type="file"> parity with regular browsers from
// one page:
//   - single file selection
//   - multiple file selection
//   - directory upload (webkitdirectory)
//   - accept filters (MIME wildcard and extension)
//   - cancellation (no stale files delivered to the page)
//   - drag/drop of files from Finder/Explorer into the page
//
// Two variants run the same page against different renderers:
//   - "cef"    → exercises CEF's file dialog path
//   - "native" → exercises WKWebView's runOpenPanelWithParameters / WebView2 / WebKitGTK

import { defineTest } from "../../test-framework/types";
import { BrowserWindow } from "electrobun/bun";

const FILE_UPLOAD_PAGE_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>File Picker Parity Test</title>
<style>
  body { font-family: -apple-system, sans-serif; padding: 20px; color: #222; }
  h1 { margin: 0 0 4px 0; font-size: 18px; }
  h2 { margin: 18px 0 4px 0; font-size: 11px; color: #555; text-transform: uppercase; letter-spacing: 0.5px; }
  p { margin: 0 0 10px 0; color: #555; font-size: 13px; }
  label { display: block; margin: 8px 0 2px 0; font-size: 13px; font-weight: 600; }
  label code { color: #888; font-size: 11px; font-weight: 400; }
  input[type="file"] { display: block; font-size: 12px; margin-bottom: 2px; }
  .result {
    font-family: ui-monospace, monospace;
    font-size: 11px;
    color: #444;
    background: #f7f7f7;
    border: 1px solid #e3e3e3;
    border-radius: 4px;
    padding: 4px 6px;
    min-height: 16px;
    white-space: pre-wrap;
    max-height: 90px;
    overflow-y: auto;
  }
  #drop-zone {
    margin-top: 6px;
    padding: 24px 12px;
    border: 2px dashed #bbb;
    border-radius: 8px;
    text-align: center;
    font-size: 13px;
    color: #777;
  }
  #drop-zone.active { border-color: #4a90d9; color: #4a90d9; background: #f0f7ff; }
  #log {
    margin-top: 14px;
    padding: 10px;
    background: #f0f0f0;
    border-radius: 6px;
    font-family: ui-monospace, monospace;
    font-size: 12px;
    white-space: pre-wrap;
    max-height: 160px;
    overflow-y: auto;
  }
</style>
</head>
<body>
  <h1>File Picker Parity Test</h1>
  <p>Use each control below, including cancelling the picker. Selections are listed per control and in the log.</p>

  <h2>File inputs</h2>
  <label>Single file <code>&lt;input type="file"&gt;</code></label>
  <input type="file" id="single">
  <div class="result" id="single-result"></div>

  <label>Multiple files <code>&lt;input type="file" multiple&gt;</code></label>
  <input type="file" id="multiple" multiple>
  <div class="result" id="multiple-result"></div>

  <label>Directory <code>&lt;input type="file" webkitdirectory&gt;</code></label>
  <input type="file" id="directory" webkitdirectory>
  <div class="result" id="directory-result"></div>

  <h2>Accept filters</h2>
  <label>Images only <code>accept="image/*"</code></label>
  <input type="file" id="images" accept="image/*" multiple>
  <div class="result" id="images-result"></div>

  <label>PDF only <code>accept=".pdf"</code></label>
  <input type="file" id="pdf" accept=".pdf">
  <div class="result" id="pdf-result"></div>

  <h2>Drag and drop</h2>
  <div id="drop-zone">Drop files or folders from Finder here</div>
  <div class="result" id="drop-result"></div>

  <div id="log">Pick or drop files above to begin.</div>

<script>
  const logEl = document.getElementById('log');
  function log(msg) { logEl.textContent = msg + '\\n' + logEl.textContent; }

  function describeFile(file) {
    const path = file.webkitRelativePath && file.webkitRelativePath.length > 0
      ? file.webkitRelativePath
      : file.name;
    return path + ' (' + (file.type || 'unknown type') + ', ' + file.size + ' bytes)';
  }

  function describeFileList(files) {
    if (!files || files.length === 0) return '(no files)';
    return files.length + ' file(s):\\n' + Array.from(files).map(describeFile).join('\\n');
  }

  function setupInput(id, label) {
    const input = document.getElementById(id);
    const result = document.getElementById(id + '-result');
    result.textContent = '(no files)';
    input.addEventListener('change', () => {
      result.textContent = describeFileList(input.files);
      log(label + ' change → ' + (input.files.length || 'no') + ' file(s)');
    });
    // Fired by browsers when the picker is dismissed without choosing.
    input.addEventListener('cancel', () => {
      log(label + ' cancelled (files unchanged: ' + input.files.length + ')');
    });
  }

  setupInput('single', 'Single');
  setupInput('multiple', 'Multiple');
  setupInput('directory', 'Directory');
  setupInput('images', 'Images (image/*)');
  setupInput('pdf', 'PDF (.pdf)');

  const dropZone = document.getElementById('drop-zone');
  const dropResult = document.getElementById('drop-result');
  dropResult.textContent = '(nothing dropped)';

  ['dragenter', 'dragover'].forEach((name) => {
    dropZone.addEventListener(name, (e) => {
      e.preventDefault();
      dropZone.classList.add('active');
    });
  });
  dropZone.addEventListener('dragleave', () => dropZone.classList.remove('active'));
  dropZone.addEventListener('drop', (e) => {
    e.preventDefault();
    dropZone.classList.remove('active');
    const items = e.dataTransfer && e.dataTransfer.items;
    const entries = [];
    if (items) {
      for (const item of items) {
        const entry = typeof item.webkitGetAsEntry === 'function' ? item.webkitGetAsEntry() : null;
        if (entry && entry.isDirectory) entries.push(entry.name + '/ (directory)');
      }
    }
    const files = e.dataTransfer ? Array.from(e.dataTransfer.files) : [];
    const lines = entries.concat(files.map(describeFile));
    dropResult.textContent = lines.length > 0 ? lines.join('\\n') : '(no files in drop)';
    log('Drop → ' + (lines.length || 'no') + ' item(s)');
  });
</script>
</body>
</html>`;

async function startFileUploadServer() {
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch() {
      return new Response(FILE_UPLOAD_PAGE_HTML, {
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    },
  });
  return server;
}

function createFileUploadTest(renderer: "cef" | "native") {
  const rendererLabel =
    renderer === "cef" ? "CEF" : "native (WKWebView/WebView2/WebKitGTK)";
  return defineTest({
    name: `File picker parity - ${rendererLabel}`,
    category: "File Upload (Interactive)",
    description: `Verify <input type="file"> single/multiple/directory selection, accept filters, cancellation, and Finder drag/drop. Exercises the ${rendererLabel} open-panel path.`,
    interactive: true,
    timeout: 600000,
    async run({ log, showInstructions }) {
      await showInstructions([
        `A diagnostic upload page will open in a ${rendererLabel} window.`,
        "Single: pick one file — the panel should be a sheet on the window (macOS native) and allow exactly one file.",
        "Multiple: verify the panel allows selecting several files at once.",
        "Directory: the panel should only allow choosing a folder; the page should list its contents with relative paths.",
        "Images (image/*): non-image files should be greyed out / unselectable in the panel.",
        "PDF (.pdf): only .pdf files should be selectable.",
        "Cancel: select a file, reopen the same picker and cancel — the previous selection must remain and no stale files appear.",
        "Drag files (and a folder) from Finder onto the drop zone — dropped names should be listed.",
        "Close the window to pass the test.",
      ]);

      const server = await startFileUploadServer();
      const url = `http://127.0.0.1:${server.port}/`;
      log(`File upload test server listening at ${url}`);

      try {
        await new Promise<void>((resolve) => {
          const win = new BrowserWindow({
            title: `File Picker Parity Test (${rendererLabel})`,
            url,
            renderer,
            frame: { width: 520, height: 860, x: 200, y: 80 },
          });

          win.setAlwaysOnTop(true);

          win.on("close", () => {
            log("File upload test window closed");
            resolve();
          });
        });
      } finally {
        server.stop(true);
        log("File upload test server stopped");
      }
    },
  });
}

export const fileUploadTests = [
  createFileUploadTest("cef"),
  createFileUploadTest("native"),
];
