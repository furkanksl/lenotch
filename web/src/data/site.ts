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
  | "inbox";

export interface ToolItem {
  id: ToolId;
  name: string;
  description: string;
}

export interface FaqItem {
  question: string;
  answer: string;
}

export const siteConfig = {
  /** Set to your product demo MP4/WebM path when ready (for example "/demo.mp4"). */
  demoVideoSrc: null as string | null,
  demoPosterSrc: null as string | null,
};

export const tools: readonly ToolItem[] = [
  {
    id: "now-playing",
    name: "Now Playing",
    description: "See what’s playing and pause, skip, or scrub from the notch.",
  },
  {
    id: "chat",
    name: "AI Chat",
    description: "Ask Claude or ChatGPT a question without leaving your current app.",
  },
  {
    id: "voice-mode",
    name: "ChatGPT Voice Mode",
    description: "Have a spoken conversation with ChatGPT. Experimental; requires a connected account and microphone access.",
  },
  {
    id: "timer",
    name: "Timer",
    description: "Start a countdown and see how much time is left in the notch.",
  },
  {
    id: "notch-video",
    name: "Video in the Notch",
    description: "Mirror a supported video into the notch or pop it out into picture-in-picture.",
  },
  {
    id: "agent-sessions",
    name: "Agent Sessions",
    description: "Follow Claude and Codex coding sessions and respond to permission prompts after setting up hooks.",
  },
  {
    id: "shelf",
    name: "Shelf",
    description: "Hold files to drag into another app.",
  },
  {
    id: "launcher",
    name: "Launcher",
    description: "Open saved apps, folders, and links.",
  },
  {
    id: "clipboard",
    name: "Clipboard",
    description: "Find and paste recently copied text.",
  },
  {
    id: "dictation",
    name: "Dictation",
    description: "Turn speech into text. Requires Apple silicon.",
  },
  {
    id: "prompter",
    name: "Prompter",
    description: "Scroll your script below the camera.",
  },
  {
    id: "today",
    name: "Today",
    description: "See today's calendar and your next meeting.",
  },
  {
    id: "todo",
    name: "To-do",
    description: "Keep a task list on your Mac.",
  },
  {
    id: "notes",
    name: "Notes",
    description: "Jot down notes that save on your Mac.",
  },
  {
    id: "shortcuts",
    name: "Shortcuts",
    description: "Run your macOS Shortcuts.",
  },
  {
    id: "system",
    name: "System",
    description: "Check CPU, memory, and disk usage.",
  },
  {
    id: "usage",
    name: "Usage",
    description: "See how much of your Claude and Codex limits you've used.",
  },
  {
    id: "inbox",
    name: "Inbox",
    description: "Read recent macOS notifications.",
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
