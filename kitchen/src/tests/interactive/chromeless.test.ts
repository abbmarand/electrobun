// Interactive Chromeless/Transparent Window Tests

import { defineTest } from "../../test-framework/types";
import { BrowserView, BrowserWindow } from "electrobun/bun";

export const chromelessTests = [
  defineTest({
    name: "Custom titlebar with window controls",
    category: "Chromeless Windows (Interactive)",
    description: "Test custom titlebar with draggable region and custom close/minimize/maximize buttons",
    interactive: true,
    timeout: 120000,
    async run({ log, showInstructions, waitForUserVerification }) {
      await showInstructions([
        "A window with a custom titlebar will open",
        "Test the following:",
        "- Drag the window by the dark titlebar area",
        "- Click the colored buttons (close, minimize, maximize)",
        "- Verify text input works in the content area",
        "Click Pass if all controls work correctly",
      ]);

      log("Opening custom titlebar test window");

      await new Promise<void>((resolve, _reject) => {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        let winRef: BrowserWindow<any> | null = null;
        let isMaximized = false;

        const rpc = BrowserView.defineRPC<any>({
          maxRequestTime: 120000,
          handlers: {
            requests: {
              closeWindow: () => {
                log("Close button clicked");
                winRef?.close();
                return { success: true };
              },
              minimizeWindow: () => {
                log("Minimize button clicked");
                winRef?.minimize();
                return { success: true };
              },
              maximizeWindow: () => {
                if (isMaximized) {
                  log("Unmaximize button clicked");
                  winRef?.unmaximize();
                  isMaximized = false;
                } else {
                  log("Maximize button clicked");
                  winRef?.maximize();
                  isMaximized = true;
                }
                return { success: true };
              },
            },
            messages: {},
          },
        });

        winRef = new BrowserWindow({
          title: "Custom Titlebar",
          url: "views://playgrounds/custom-titlebar/index.html",
          renderer: "cef",
          frame: { width: 500, height: 700, x: 150, y: 50 },
          // 'hidden' titleBarStyle hides both titlebar AND native window controls
          titleBarStyle: "hidden",
          rpc,
        });

        winRef.setAlwaysOnTop(true);
        const win = winRef;

        win.on("close", () => {
          log("Window closed");
          resolve();
        });
      });

      // Wait for user verification
      const result = await waitForUserVerification();
      if (result.action === "fail") {
        throw new Error(result.notes || "User marked test as failed");
      }
      if (result.action === "retest") {
        throw new Error("RETEST: User requested to run the test again");
      }

      log("Custom titlebar test completed");
    },
  }),

  defineTest({
    name: "Transparent/borderless window for floating UI",
    category: "Chromeless Windows (Interactive)",
    description: "Test transparent window with custom-shaped floating UI elements",
    interactive: true,
    timeout: 120000,
    async run({ log, showInstructions, waitForUserVerification }) {
      await showInstructions([
        "A transparent borderless window will open",
        "The window background should be transparent/see-through",
        "Test the following:",
        "- Verify you can see through the window background",
        "- Drag any of the floating cards to move the window",
        "- Click the red close button when done",
        "Click Pass if transparency and dragging work",
      ]);

      log("Opening transparent window test");

      await new Promise<void>((resolve, _reject) => {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        let winRef: BrowserWindow<any> | null = null;

        const rpc = BrowserView.defineRPC<any>({
          maxRequestTime: 120000,
          handlers: {
            requests: {
              closeWindow: () => {
                log("Close button clicked");
                winRef?.close();
                return { success: true };
              },
            },
            messages: {},
          },
        });

        winRef = new BrowserWindow({
          title: "Transparent Window",
          url: "views://playgrounds/transparent-window/index.html",
          renderer: "cef",
          frame: { width: 450, height: 500, x: 200, y: 100 },
          // 'hidden' titleBarStyle hides titlebar and native controls
          titleBarStyle: "hidden",
          // transparent: true makes window background see-through
          transparent: true,
          rpc,
        });

        winRef.setAlwaysOnTop(true);
        const win = winRef;

        win.on("close", () => {
          log("Window closed");
          resolve();
        });
      });

      // Wait for user verification
      const result = await waitForUserVerification();
      if (result.action === "fail") {
        throw new Error(result.notes || "User marked test as failed");
      }
      if (result.action === "retest") {
        throw new Error("RETEST: User requested to run the test again");
      }

      log("Transparent window test completed");
    },
  }),

  defineTest({
    name: "Hidden transparent native window paints on inactive reveal",
    category: "Chromeless Windows (Interactive)",
    description:
      "Regression test for compact floating UI that was transparent until its first resize",
    interactive: true,
    timeout: 120000,
    async run({ log, showInstructions, waitForUserVerification }) {
      if (process.platform !== "darwin") {
        log("Skipping: first-paint regression target is macOS-specific");
        return;
      }

      await showInstructions([
        "A compact purple card will be created while hidden, then shown without activation.",
        "Verify the card is visible immediately without moving or resizing it.",
        "Mark the test as failed if the window is empty or fully transparent.",
      ]);

      const win = new BrowserWindow({
        title: "Hidden Transparent First Paint",
        html: `<!doctype html>
          <style>
            html, body { margin: 0; width: 100%; height: 100%; background: transparent; }
            body { display: grid; place-items: center; font: 13px -apple-system, sans-serif; }
            .card { box-sizing: border-box; width: 100%; height: 100%; padding: 14px 18px; color: white; background: #6d4aff; border-radius: 16px; }
          </style>
          <div class="card">Compact window painted before resize</div>`,
        renderer: "native",
        frame: { width: 300, height: 60, x: 160, y: 120 },
        titleBarStyle: "hidden",
        transparent: true,
        hidden: true,
        activate: false,
      });

      try {
        await new Promise((resolve) => setTimeout(resolve, 300));
        win.showInactive();
        log("Hidden transparent window revealed without resizing");

        const result = await waitForUserVerification();
        if (result.action === "fail") {
          throw new Error(result.notes || "Window did not paint on inactive reveal");
        }
        if (result.action === "retest") {
          throw new Error("RETEST: User requested another run");
        }
      } finally {
        win.close();
      }

      log("Hidden transparent first-paint regression test completed");
    },
  }),
];
