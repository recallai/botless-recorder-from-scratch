import { execFile } from "node:child_process";
import { promisify } from "node:util";

import type { AutomationStatus } from "../../shared/ipc";
import type { ChromeTabSnapshot } from "./types";

const execFileAsync = promisify(execFile);
const TAB_SNAPSHOT_FALLBACK_MS = 30_000;

export class ChromeTabDetector {
  private lastSuccessfulTabs: ChromeTabSnapshot[] = [];
  private lastSuccessfulReadAt = 0;

  async getAutomationStatus(): Promise<AutomationStatus> {
    if (process.platform !== "darwin") {
      return "unknown";
    }

    try {
      await execFileAsync("osascript", ["-e", this.chromeTabsScript()]);
      return "granted";
    } catch (error) {
      const output = String(error);

      if (output.includes("not authorized") || output.includes("1743")) {
        return "denied";
      }

      return "unknown";
    }
  }

  async readTabs(): Promise<ChromeTabSnapshot[]> {
    if (process.platform !== "darwin") {
      return [];
    }

    try {
      const { stdout } = await execFileAsync("osascript", ["-e", this.chromeTabsScript()]);

      const tabs = stdout
        .split(String.fromCharCode(31))
        .map((line) => line.trim())
        .filter((line) => line.length > 0)
        .map((line) => {
          const [windowIndex, frontmostFlag, activeFlag, title, url] = line.split(String.fromCharCode(30));

          return {
            windowIndex: Number(windowIndex) || 0,
            isFrontmostWindow: frontmostFlag === "frontmost",
            isActiveTab: activeFlag === "active",
            title: title ?? "",
            url: url ?? ""
          };
        });

      this.lastSuccessfulTabs = tabs;
      this.lastSuccessfulReadAt = Date.now();
      return tabs;
    } catch (error) {
      console.warn(`[detector] Unable to read Chrome tabs: ${String(error)}`);

      // Short-lived AppleScript failures are common while Chrome is changing
      // windows or tabs. Reusing a recent successful snapshot avoids turning a
      // transient automation blip into a false "meeting disappeared" signal.
      if (this.lastSuccessfulTabs.length > 0 && Date.now() - this.lastSuccessfulReadAt <= TAB_SNAPSHOT_FALLBACK_MS) {
        console.warn("[detector] Falling back to last successful Chrome tab snapshot");
        return this.lastSuccessfulTabs;
      }

      return [];
    }
  }

  async requestGoogleMeetPopup(meetingUrl: string): Promise<{ ok: boolean; message: string }> {
    if (process.platform !== "darwin") {
      return { ok: false, message: "Google Meet popup automation is only supported on macOS" };
    }

    try {
      const { stdout } = await execFileAsync("osascript", ["-e", this.googleMeetPopupScript(meetingUrl)]);
      const message = stdout.trim() || "Google Meet popup automation requested";
      const ok = message.startsWith("OK:");
      return {
        ok,
        message: message.replace(/^OK:\s*/, "").replace(/^ERROR:\s*/, "")
      };
    } catch (error) {
      const message = String(error);
      if (message.includes("Allow JavaScript from Apple Events") || message.includes("(12)")) {
        return {
          ok: false,
          message: "Chrome blocked popup automation because 'Allow JavaScript from Apple Events' is off. Open the Google Meet picture-in-picture popup manually or enable that Chrome developer setting."
        };
      }

      return {
        ok: false,
        message: `Google Meet popup automation failed: ${message}`
      };
    }
  }

  async ensureGoogleMeetCaptions(meetingUrl: string): Promise<{ ok: boolean; message: string }> {
    if (process.platform !== "darwin") {
      return { ok: false, message: "Google Meet caption automation is only supported on macOS" };
    }

    const javascript = [
      "(()=>{",
      "const normalize=(value)=>String(value||'').toLowerCase().trim();",
      "const hasVisibleCaptionText=()=>Array.from(document.querySelectorAll('[aria-live]')).some((element)=>{",
      "const style=window.getComputedStyle(element);",
      "return style.display!=='none'&&style.visibility!=='hidden'&&Boolean(element.textContent&&element.textContent.trim().length);",
      "});",
      "if(hasVisibleCaptionText()) return 'already-on';",
      "const controls=Array.from(document.querySelectorAll('button,[role=button],[aria-label],[title]'));",
      "for(const element of controls){",
      "const values=[element.getAttribute('aria-label'),element.getAttribute('title'),element.textContent].map(normalize).filter(Boolean);",
      "if(values.some((value)=>value.includes('turn off captions')||value.includes('captions are on')||value==='captions')) return 'already-on';",
      "if(values.some((value)=>value.includes('turn on captions')||value.includes('show captions'))){element.click();return 'clicked';}",
      "}",
      "return 'not-found';",
      "})();"
    ].join("");

    try {
      const result = (await this.executeGoogleMeetJavascript(meetingUrl, javascript)).trim();
      return {
        ok: result === "already-on" || result === "clicked",
        message: result
      };
    } catch (error) {
      return {
        ok: false,
        message: this.formatJavascriptError(error)
      };
    }
  }

  async readGoogleMeetCaptions(meetingUrl: string): Promise<Array<{ speaker: string; text: string }>> {
    if (process.platform !== "darwin") {
      return [];
    }

    const javascript = [
      "(()=>{",
      "try{",
      "const badgeSelector='.NWpY1d, .xoMHSc';",
      "const normalize=(value)=>String(value||'').replace(/\\s+/g,' ').trim();",
      "const rows=[];",
      "const seen=new Set();",
      "const badges=Array.from(document.querySelectorAll(badgeSelector));",
      "for(const badge of badges){",
      "const speaker=normalize(badge.textContent);",
      "if(!speaker) continue;",
      "let row=badge.parentElement;",
      "for(let i=0;i<6&&row;i+=1){",
      "const clone=row.cloneNode(true);",
      "if(!(clone instanceof HTMLElement)) break;",
      "clone.querySelectorAll(badgeSelector).forEach((element)=>element.remove());",
      "const text=normalize(clone.textContent);",
      "const visible=window.getComputedStyle(row).display!=='none'&&window.getComputedStyle(row).visibility!=='hidden';",
      "if(visible&&text&&text.toLowerCase()!==speaker.toLowerCase()){",
      "const key=`${speaker}::${text}`;",
      "if(!seen.has(key)){seen.add(key);rows.push({speaker,text,top:row.getBoundingClientRect().top});}",
      "break;",
      "}",
      "row=row.parentElement;",
      "}",
      "}",
      "rows.sort((left,right)=>left.top-right.top);",
      "return '__CAPTIONS__'+encodeURIComponent(JSON.stringify(rows.map(({speaker,text})=>({speaker,text}))));",
      "}catch(error){",
      "return '__CAPTION_ERROR__'+String(error&&error.message?error.message:error);",
      "}",
      "})();"
    ].join("");

    try {
      const output = await this.executeGoogleMeetJavascript(meetingUrl, javascript);
      const trimmed = output.trim();

      if (trimmed.length === 0 || trimmed === "undefined" || trimmed === "null") {
        return [];
      }

      if (trimmed.startsWith("__CAPTION_ERROR__")) {
        console.warn(`[detector] Unable to read Google Meet captions: ${trimmed.replace("__CAPTION_ERROR__", "")}`);
        return [];
      }

      if (!trimmed.startsWith("__CAPTIONS__")) {
        console.warn(`[detector] Unexpected Google Meet caption payload: ${trimmed.slice(0, 120)}`);
        return [];
      }

      const encodedPayload = trimmed.slice("__CAPTIONS__".length);
      const decodedPayload = decodeURIComponent(encodedPayload);
      const parsed = JSON.parse(decodedPayload) as Array<{ speaker?: string; text?: string }>;
      return parsed
        .map((entry) => ({
          speaker: String(entry.speaker ?? "").trim(),
          text: String(entry.text ?? "").trim()
        }))
        .filter((entry) => entry.speaker.length > 0 && entry.text.length > 0);
    } catch (error) {
      console.warn(`[detector] Unable to read Google Meet captions: ${this.formatJavascriptError(error)}`);
      return [];
    }
  }

  private chromeTabsScript(): string {
    return `
      tell application "Google Chrome"
        if not running then
          return ""
        end if

        set tabRows to {}
        set fieldDelimiter to ASCII character 30
        set recordDelimiter to ASCII character 31

        repeat with windowRef in every window
          set frontmostFlag to "background"
          set activeTabIndex to 0
          set tabCount to 0

          try
            if index of windowRef is 1 then
              set frontmostFlag to "frontmost"
            end if
          end try

          try
            set activeTabIndex to active tab index of windowRef
            set tabCount to count of tabs of windowRef
          on error
            set activeTabIndex to 0
            set tabCount to 0
          end try

          repeat with tabIndex from 1 to tabCount
            set tabRef to missing value
            set activeFlag to "background"
            set tabTitle to ""
            set tabUrl to ""

            if tabIndex is activeTabIndex then
              set activeFlag to "active"
            end if

            try
              set tabRef to tab tabIndex of windowRef
            end try

            if tabRef is not missing value then
              try
                set tabTitle to (title of tabRef as text)
              end try

              try
                set tabUrl to (URL of tabRef as text)
              end try
            end if

            set end of tabRows to ((index of windowRef as text) & fieldDelimiter & frontmostFlag & fieldDelimiter & activeFlag & fieldDelimiter & tabTitle & fieldDelimiter & tabUrl)
          end repeat
        end repeat
        set AppleScript's text item delimiters to recordDelimiter
        set joinedRows to tabRows as text
        set AppleScript's text item delimiters to ""
        return joinedRows
      end tell
    `;
  }

  private googleMeetPopupScript(meetingUrl: string): string {
    const meetingCodeMatch = meetingUrl.match(/meet\.google\.com\/([a-z]{3}-[a-z]{4}-[a-z]{3})/i);
    const meetingCode = meetingCodeMatch?.[1] ?? "";
    const escapedMeetingUrl = meetingUrl.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
    const escapedMeetingCode = meetingCode.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
    const popupJavascript = [
      "(()=>{",
      "const normalize=(value)=>String(value||'').toLowerCase().trim();",
      "const pipCandidates=['picture-in-picture','picture in picture','open picture-in-picture','open picture in picture','pop-out','pop out','open in picture-in-picture','open in picture in picture','switch to picture-in-picture','open picture-in-picture mode','open in a small window','small window'];",
      "const moreCandidates=['more options','more actions','more'];",
      "const selector='button,[role=button],[role=menuitem],[aria-label],[title]';",
      "const controlValues=(element)=>[element.getAttribute('aria-label'),element.getAttribute('title'),element.textContent].map(normalize).filter(Boolean);",
      "const visibleControls=()=>Array.from(document.querySelectorAll(selector)).filter((element)=>{",
      "const style=window.getComputedStyle(element);",
      "return style.display!=='none'&&style.visibility!=='hidden';",
      "});",
      "const findMatchingControl=(candidates)=>{",
      "for(const element of visibleControls()){",
      "const values=controlValues(element);",
      "if(values.some((value)=>candidates.some((candidate)=>value.includes(candidate)))) return {element,values};",
      "}",
      "return null;",
      "};",
      "const debugSummary=()=>visibleControls().map((element)=>controlValues(element).join('|')).filter(Boolean).filter((value)=>/(picture|pop|small window|window|more|options)/.test(value)).slice(0,12).join(' || ');",
      "const directMatch=findMatchingControl(pipCandidates);",
      "if(directMatch){directMatch.element.click();return 'clicked:'+directMatch.values.join('|');}",
      "const moreMatch=findMatchingControl(moreCandidates);",
      "if(moreMatch){",
      "moreMatch.element.click();",
      "const afterMenuMatch=findMatchingControl(pipCandidates);",
      "if(afterMenuMatch){afterMenuMatch.element.click();return 'clicked-after-menu:'+afterMenuMatch.values.join('|');}",
      "return 'not-found-after-menu:'+debugSummary();",
      "}",
      "return 'not-found:'+debugSummary();",
      "})();"
    ].join("").replace(/\\/g, "\\\\").replace(/"/g, "\\\"");

    return `
      set targetUrl to "${escapedMeetingUrl}"
      set targetMeetingCode to "${escapedMeetingCode}"
      set popupJavascript to "${popupJavascript}"

      tell application "Google Chrome"
        if not running then
          return "ERROR: Google Chrome is not running"
        end if

        set targetTab to missing value

        repeat with windowRef in every window
          repeat with tabRef in every tab of windowRef
            try
              set tabUrl to (URL of tabRef as text)

              if tabUrl is targetUrl then
                set targetTab to tabRef
                exit repeat
              end if

              if targetMeetingCode is not "" and tabUrl contains ("meet.google.com/" & targetMeetingCode) then
                set targetTab to tabRef
                exit repeat
              end if
            end try
          end repeat

          if targetTab is not missing value then
            exit repeat
          end if
        end repeat

        if targetTab is missing value then
          return "ERROR: Could not find Google Meet tab for URL"
        end if

        set popupResult to execute targetTab javascript popupJavascript

        if popupResult starts with "clicked:" or popupResult starts with "clicked-after-menu:" then
          return "OK: " & popupResult
        end if

        if popupResult starts with "not-found-after-menu:" then
          return "ERROR: Google Meet popup button not found after opening More options (" & text ((length of "not-found-after-menu:") + 1) thru -1 of popupResult & ")"
        end if

        if popupResult starts with "not-found:" then
          return "ERROR: Google Meet popup button not found in page controls (" & text ((length of "not-found:") + 1) thru -1 of popupResult & ")"
        end if

        return "ERROR: Google Meet popup button not found in page controls"
      end tell
    `;
  }

  private async executeGoogleMeetJavascript(meetingUrl: string, javascript: string): Promise<string> {
    const { stdout } = await execFileAsync("osascript", ["-e", this.googleMeetJavascriptScript(meetingUrl, javascript)]);
    return stdout.trim();
  }

  private formatJavascriptError(error: unknown): string {
    const message = String(error);

    if (message.includes("Allow JavaScript from Apple Events") || message.includes("Executing JavaScript through AppleScript is turned off")) {
      return "Chrome blocked JavaScript from Apple Events. Enable 'Allow JavaScript from Apple Events' in Chrome Developer Settings.";
    }

    return message;
  }

  private googleMeetJavascriptScript(meetingUrl: string, javascript: string): string {
    const meetingCodeMatch = meetingUrl.match(/meet\.google\.com\/([a-z]{3}-[a-z]{4}-[a-z]{3})/i);
    const meetingCode = meetingCodeMatch?.[1] ?? "";
    const escapedMeetingUrl = meetingUrl.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
    const escapedMeetingCode = meetingCode.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
    const escapedJavascript = javascript.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");

    return `
      set targetUrl to "${escapedMeetingUrl}"
      set targetMeetingCode to "${escapedMeetingCode}"
      set scriptSource to "${escapedJavascript}"

      tell application "Google Chrome"
        if not running then
          return ""
        end if

        set targetTab to missing value

        repeat with windowRef in every window
          repeat with tabRef in every tab of windowRef
            try
              set tabUrl to (URL of tabRef as text)

              if tabUrl is targetUrl then
                set targetTab to tabRef
                exit repeat
              end if

              if targetMeetingCode is not "" and tabUrl contains ("meet.google.com/" & targetMeetingCode) then
                set targetTab to tabRef
                exit repeat
              end if
            end try
          end repeat

          if targetTab is not missing value then
            exit repeat
          end if
        end repeat

        if targetTab is missing value then
          return ""
        end if

        return execute targetTab javascript scriptSource
      end tell
    `;
  }
}
