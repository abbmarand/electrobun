// Interactive fullscreen tests

import { BrowserWindow } from "electrobun/bun";
import { defineTest } from "../../test-framework/types";

const FULLSCREEN_TEST_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Fullscreen Regression</title>
<style>
  body {
    margin: 0;
    padding: 20px;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    color: #1f2937;
    background: #f6f7f9;
  }
  h1 {
    margin: 0 0 4px;
    font-size: 20px;
  }
  h2 {
    margin: 0 0 8px;
    font-size: 13px;
    text-transform: uppercase;
    color: #5b6472;
  }
  p {
    margin: 0 0 14px;
    color: #5b6472;
    font-size: 13px;
    line-height: 1.45;
  }
  main {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
  }
  section {
    border: 1px solid #d8dde6;
    border-radius: 8px;
    padding: 14px;
    background: #fff;
  }
  .player {
    position: relative;
    overflow: hidden;
    border-radius: 8px;
    background: #0d1117;
  }
  video {
    display: block;
    width: 100%;
    aspect-ratio: 16 / 9;
    background: #0d1117;
    object-fit: contain;
  }
  .stage {
    min-height: 330px;
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
    border-radius: 8px;
    padding: 12px;
    background: #202124;
    color: #fff;
  }
  .tile {
    display: grid;
    place-items: center;
    border-radius: 8px;
    background: #303134;
    font-size: 13px;
  }
  .tile.primary {
    grid-column: span 2;
    min-height: 170px;
    background: #263238;
  }
  .actions {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 10px;
  }
  button {
    min-height: 32px;
    border: 1px solid #c8ced8;
    border-radius: 7px;
    padding: 6px 10px;
    background: #fff;
    color: #1f2937;
    font: inherit;
    font-size: 13px;
    cursor: pointer;
  }
  button:hover {
    background: #eef2f7;
  }
  #log {
    grid-column: span 2;
    min-height: 130px;
    max-height: 220px;
    overflow: auto;
    border: 1px solid #d8dde6;
    border-radius: 8px;
    padding: 10px;
    background: #fff;
    white-space: pre-wrap;
    font: 12px ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  canvas {
    display: none;
  }
</style>
</head>
<body>
<h1>Fullscreen Regression</h1>
<p>Use these controls to verify browser-style fullscreen, Escape exit, and frame restore in native site windows.</p>
<main>
  <section>
    <h2>YouTube-style video page</h2>
    <div class="player">
      <video id="video" muted playsinline controls></video>
    </div>
    <div class="actions">
      <button id="start-video">Start Video</button>
      <button id="video-fullscreen">Video Fullscreen</button>
    </div>
  </section>

  <section>
    <h2>Google Meet-style stage</h2>
    <div class="stage" id="stage">
      <div class="tile primary">Shared presentation</div>
      <div class="tile">Participant A</div>
      <div class="tile">Participant B</div>
    </div>
    <div class="actions">
      <button id="stage-fullscreen">Stage Fullscreen</button>
      <button id="page-fullscreen">Page Fullscreen</button>
      <button id="exit-fullscreen">Exit Fullscreen</button>
    </div>
  </section>

  <div id="log">Ready.</div>
</main>
<canvas id="canvas" width="1280" height="720"></canvas>
<script>
  const logEl = document.getElementById('log');
  const video = document.getElementById('video');
  const canvas = document.getElementById('canvas');
  const stage = document.getElementById('stage');
  const context = canvas.getContext('2d');
  let frame = 0;
  let drawing = false;

  function log(message) {
    logEl.textContent = '[' + new Date().toLocaleTimeString() + '] ' + message + '\\n' + logEl.textContent;
  }

  function hasFunction(target, name) {
    return !!target && typeof target[name] === 'function';
  }

  function draw() {
    if (!drawing || !context) return;
    const hue = (frame * 4) % 360;
    context.fillStyle = 'hsl(' + hue + ' 58% 20%)';
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.fillStyle = 'hsl(' + ((hue + 110) % 360) + ' 72% 48%)';
    context.fillRect(80 + (frame % 420), 100, 260, 160);
    context.fillStyle = '#fff';
    context.font = 'bold 64px -apple-system, BlinkMacSystemFont, sans-serif';
    context.fillText('YouTube-style test video', 80, 410);
    context.font = '34px ui-monospace, SFMono-Regular, Menlo, monospace';
    context.fillText('frame ' + frame, 80, 468);
    frame += 1;
    requestAnimationFrame(draw);
  }

  async function startVideo() {
    if (!context || !hasFunction(canvas, 'captureStream')) {
      log('Canvas captureStream unavailable.');
      return;
    }
    if (!video.srcObject) {
      video.srcObject = canvas.captureStream(30);
      log('Attached generated media stream.');
    }
    if (!drawing) {
      drawing = true;
      draw();
    }
    try {
      await video.play();
      log('Video playing.');
    } catch (error) {
      log('Video play failed: ' + (error && error.message || error));
    }
  }

  async function requestFullscreen(element, label) {
    if (element === video && !video.srcObject) await startVideo();
    try {
      if (hasFunction(element, 'requestFullscreen')) {
        await element.requestFullscreen();
        log(label + ' requestFullscreen resolved.');
      } else if (hasFunction(element, 'webkitRequestFullscreen')) {
        element.webkitRequestFullscreen();
        log(label + ' webkitRequestFullscreen called.');
      } else if (element === video && hasFunction(video, 'webkitEnterFullscreen')) {
        video.webkitEnterFullscreen();
        log(label + ' webkitEnterFullscreen called.');
      } else {
        log(label + ' fullscreen API unavailable.');
      }
    } catch (error) {
      log(label + ' fullscreen failed: ' + (error && error.message || error));
    }
  }

  async function exitFullscreen() {
    try {
      if (hasFunction(document, 'exitFullscreen')) {
        await document.exitFullscreen();
        log('document.exitFullscreen resolved.');
      } else if (hasFunction(document, 'webkitExitFullscreen')) {
        document.webkitExitFullscreen();
        log('document.webkitExitFullscreen called.');
      } else {
        log('Exit fullscreen API unavailable.');
      }
    } catch (error) {
      log('Exit fullscreen failed: ' + (error && error.message || error));
    }
  }

  document.getElementById('start-video').addEventListener('click', function() {
    void startVideo();
  });
  document.getElementById('video-fullscreen').addEventListener('click', function() {
    void requestFullscreen(video, 'Video');
  });
  document.getElementById('stage-fullscreen').addEventListener('click', function() {
    void requestFullscreen(stage, 'Stage');
  });
  document.getElementById('page-fullscreen').addEventListener('click', function() {
    void requestFullscreen(document.documentElement, 'Page');
  });
  document.getElementById('exit-fullscreen').addEventListener('click', function() {
    void exitFullscreen();
  });

  document.addEventListener('fullscreenchange', function() {
    log('fullscreenchange: ' + (document.fullscreenElement ? 'entered' : 'exited'));
  });
  document.addEventListener('webkitfullscreenchange', function() {
    log('webkitfullscreenchange: ' + (document.webkitFullscreenElement ? 'entered' : 'exited'));
  });
  document.addEventListener('keydown', function(event) {
    if (event.key === 'Escape') log('Escape keydown observed.');
  });
</script>
</body>
</html>`;

function startFullscreenServer(): ReturnType<typeof Bun.serve> {
	return Bun.serve({
		hostname: "127.0.0.1",
		port: 0,
		fetch() {
			return new Response(FULLSCREEN_TEST_HTML, {
				headers: { "Content-Type": "text/html; charset=utf-8" }
			});
		}
	});
}

function frameStillRestored(
	initial: { x: number; y: number; width: number; height: number },
	current: { x: number; y: number; width: number; height: number }
): boolean {
	return (
		Math.abs(current.x - initial.x) < 80 &&
		Math.abs(current.y - initial.y) < 80 &&
		Math.abs(current.width - initial.width) < 120 &&
		Math.abs(current.height - initial.height) < 120
	);
}

export const fullscreenTests = [
	defineTest({
		name: "YouTube-style video fullscreen Escape restore (native macOS)",
		category: "Fullscreen (Interactive)",
		description: "Verify native WK video fullscreen, Escape exit, and window frame restoration.",
		interactive: true,
		timeout: 300000,
		async run({ log, showInstructions, waitForUserVerification }) {
			if (process.platform !== "darwin") {
				log("Skipping native WK fullscreen regression on non-macOS platform");
				return;
			}

			await showInstructions([
				"A native WK test page will open with a YouTube-style video surface.",
				"Click Start Video, then Video Fullscreen.",
				"Press Escape and verify the video exits fullscreen and the native toolbar/window frame returns.",
				"Click Pass if fullscreen, Escape, and frame restore all work."
			]);

			const server = startFullscreenServer();
			const url = `http://127.0.0.1:${server.port}/`;
			const win = new BrowserWindow({
				title: "YouTube-style Fullscreen Regression",
				url,
				renderer: "native",
				frame: { width: 980, height: 720, x: 180, y: 90 }
			});
			const initialFrame = win.getFrame();

			try {
				const result = await waitForUserVerification();
				if (result.action === "fail") {
					throw new Error(result.notes || "User marked YouTube-style fullscreen test as failed");
				}
				if (result.action === "retest") {
					throw new Error("RETEST: User requested to run the YouTube-style fullscreen test again");
				}

				const restoredFrame = win.getFrame();
				if (!frameStillRestored(initialFrame, restoredFrame)) {
					throw new Error("Window frame did not restore after video fullscreen exercise");
				}
			} finally {
				win.close();
				server.stop(true);
			}
		}
	}),

	defineTest({
		name: "Google Meet-style document fullscreen Escape restore (native macOS)",
		category: "Fullscreen (Interactive)",
		description:
			"Verify native WK document fullscreen, Escape exit, toolbar restoration, and frame restoration.",
		interactive: true,
		timeout: 300000,
		async run({ log, showInstructions, waitForUserVerification }) {
			if (process.platform !== "darwin") {
				log("Skipping native WK document fullscreen regression on non-macOS platform");
				return;
			}

			await showInstructions([
				"A native WK test page will open with a Google Meet-style stage.",
				"Click Stage Fullscreen, press Escape, and verify the stage exits fullscreen.",
				"Click Page Fullscreen, press Escape, and verify the native toolbar/window frame returns.",
				"Click Pass if document fullscreen, Escape, and frame restore all work."
			]);

			const server = startFullscreenServer();
			const url = `http://127.0.0.1:${server.port}/`;
			const win = new BrowserWindow({
				title: "Meet-style Fullscreen Regression",
				url,
				renderer: "native",
				frame: { width: 980, height: 720, x: 220, y: 110 }
			});
			const initialFrame = win.getFrame();

			try {
				const result = await waitForUserVerification();
				if (result.action === "fail") {
					throw new Error(
						result.notes || "User marked Meet-style document fullscreen test as failed"
					);
				}
				if (result.action === "retest") {
					throw new Error(
						"RETEST: User requested to run the Meet-style document fullscreen test again"
					);
				}

				const restoredFrame = win.getFrame();
				if (!frameStillRestored(initialFrame, restoredFrame)) {
					throw new Error("Window frame did not restore after document fullscreen exercise");
				}
			} finally {
				win.close();
				server.stop(true);
			}
		}
	})
];
