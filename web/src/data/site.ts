export type ToolId =
  | "now-playing"
  | "chat"
  | "voice-mode"
  | "timer"
  | "notch-video"
  | "agent-sessions"
  | "shelf"
  | "launcher"
  | "clipboard"
  | "dictation"
  | "prompter"
  | "today"
  | "todo"
  | "notes"
  | "shortcuts"
  | "system"
  | "usage"
  | "inbox"
  | "incoming-call"
  | "messages"
  | "volume"
  | "brightness"
  | "status-alerts";

export interface ToolItem {
  id: ToolId;
  name: string;
  description: string;
  recording?: string;
}

export interface FaqItem {
  question: string;
  answer: string;
}

export const tools: readonly ToolItem[] = [
  {
    id: "now-playing",
    name: "Now Playing",
    description: "See what’s playing and pause, skip, or scrub from the notch.",
    recording: "music-player.mp4",
  },
  {
    id: "chat",
    name: "AI Chat",
    description: "Ask Claude or ChatGPT a question without leaving your current app.",
    recording: "ai-text-chat.mp4",
  },
  {
    id: "voice-mode",
    name: "ChatGPT Voice Mode",
    description: "Have a spoken conversation with ChatGPT. Experimental; requires a connected account and microphone access.",
    recording: "ai-chat.mp4",
  },
  {
    id: "timer",
    name: "Timer",
    description: "Start a countdown and see how much time is left in the notch.",
    recording: "timer.mp4",
  },
  {
    id: "notch-video",
    name: "Video in the Notch",
    description: "Mirror a supported video into the notch or pop it out into picture-in-picture.",
    recording: "pip.mp4",
  },
  {
    id: "agent-sessions",
    name: "Agent Sessions",
    description: "Follow Claude and Codex coding sessions and respond to permission prompts after setting up hooks.",
    recording: "ai-coding.mp4",
  },
  {
    id: "shelf",
    name: "Shelf",
    description: "Hold files to drag into another app.",
    recording: "shelf.mp4",
  },
  {
    id: "launcher",
    name: "Launcher",
    description: "Open saved apps, folders, and links.",
    recording: "launcher.mp4",
  },
  {
    id: "clipboard",
    name: "Clipboard",
    description: "Find and paste recently copied text.",
    recording: "clipboard.mp4",
  },
  {
    id: "dictation",
    name: "Dictation",
    description: "Turn speech into text. Requires Apple silicon.",
    recording: "dictation.mp4",
  },
  {
    id: "prompter",
    name: "Prompter",
    description: "Scroll your script below the camera.",
    recording: "prompter.mp4",
  },
  {
    id: "today",
    name: "Today",
    description: "See today's calendar and your next meeting.",
    recording: "meeting.mp4",
  },
  {
    id: "todo",
    name: "To-do",
    description: "Keep a task list on your Mac.",
    recording: "todo.mp4",
  },
  {
    id: "notes",
    name: "Notes",
    description: "Jot down notes that save on your Mac.",
    recording: "notes.mp4",
  },
  {
    id: "shortcuts",
    name: "Shortcuts",
    description: "Run your macOS Shortcuts.",
    recording: "shortcuts.mp4",
  },
  {
    id: "system",
    name: "System",
    description: "Check CPU, memory, and disk usage.",
    recording: "system-info.mp4",
  },
  {
    id: "usage",
    name: "Usage",
    description: "See how much of your Claude and Codex limits you've used.",
    recording: "usage.mp4",
  },
  {
    id: "inbox",
    name: "Inbox",
    description: "Read recent macOS notifications.",
    recording: "notifications.mp4",
  },
  {
    id: "incoming-call",
    name: "Incoming Call",
    description: "Preview the incoming-call and in-call layouts in the notch.",
    recording: "incoming-call.mp4",
  },
  {
    id: "messages",
    name: "Messages",
    description: "Preview a message notification and its inline reply field.",
    recording: "messages.mp4",
  },
  {
    id: "volume",
    name: "Volume",
    description: "See the volume level in the notch when you press a volume key.",
    recording: "hud.mp4",
  },
  {
    id: "brightness",
    name: "Brightness",
    description: "See the display level in the notch when you change the brightness.",
    recording: "birghtness.mp4",
  },
  {
    id: "status-alerts",
    name: "Status Alerts",
    description: "See AirPods battery, Mac charging status, and usage-limit resets in the notch.",
    recording: "airpods-charging-limit-reset.mp4",
  },
];

export const faqs: readonly FaqItem[] = [
  {
    question: "Does my Mac need a physical notch?",
    answer:
      "No. LeNotch can draw a virtual notch on Macs without one and on external displays.",
  },
  {
    question: "Which Macs are supported?",
    answer:
      "macOS 15 Sequoia or later on Apple silicon and Intel. Dictation requires Apple silicon.",
  },
  {
    question: "Are speech models bundled in the app?",
    answer:
      "No. Offline dictation models are optional downloads. ChatGPT dictation doesn't need a local model.",
  },
  {
    question: "Where are notes, tasks, and scripts stored?",
    answer:
      "They stay on your Mac.",
  },
];
