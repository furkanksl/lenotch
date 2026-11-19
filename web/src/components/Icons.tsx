import type { ToolId } from "../data/site";

export function BrandMark(props: { class?: string }) {
  return (
    <img
      src={`${import.meta.env.BASE_URL}lenotch-logo.webp`}
      width="224"
      height="224"
      alt=""
      class={props.class ?? "h-6 w-6"}
    />
  );
}

export function ToolIcon(props: { id: ToolId; class?: string }) {
  const cls = () => props.class ?? "h-4 w-4";

  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.65"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      class={cls()}
    >
      {props.id === "chat" && (
        <>
          <path d="M9.85 4.87 8.76 8.7A3.5 3.5 0 0 1 6.7 10.76L2.87 11.85a1.19 1.19 0 0 0 0 2.3l3.83 1.09a3.5 3.5 0 0 1 2.06 2.06l1.09 3.83a1.19 1.19 0 0 0 2.3 0l1.09-3.83a3.5 3.5 0 0 1 2.06-2.06l3.83-1.09a1.19 1.19 0 0 0 0-2.3L15.3 10.76A3.5 3.5 0 0 1 13.24 8.7l-1.09-3.83a1.19 1.19 0 0 0-2.3 0Z" />
          <path d="M19.5 2.5v4M17.5 4.5h4" />
        </>
      )}
      {props.id === "dictation" && (
        <>
          <rect x="9" y="2" width="6" height="13" rx="3" />
          <path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8" />
        </>
      )}
      {props.id === "prompter" && (
        <path d="M3 4h18M3 9.5h9M3 15h18M3 20.5h9" />
      )}
      {props.id === "today" && (
        <>
          <path d="M8 2v4M16 2v4M3 10h18" />
          <rect x="3" y="4" width="18" height="18" rx="4" />
          <path d="M8 14h.01M12 14h.01M16 14h.01M8 18h.01M12 18h.01" />
        </>
      )}
      {props.id === "launcher" && (
        <>
          <rect x="3" y="3" width="7.5" height="7.5" rx="2.3" />
          <rect x="13.5" y="3" width="7.5" height="7.5" rx="2.3" />
          <rect x="3" y="13.5" width="7.5" height="7.5" rx="2.3" />
          <rect x="13.5" y="13.5" width="7.5" height="7.5" rx="2.3" />
        </>
      )}
      {props.id === "clipboard" && (
        <>
          <rect x="8" y="2" width="8" height="3.2" rx="1.5" />
          <path d="M8 3.6H6.6A2.6 2.6 0 0 0 4 6.2v13.2A2.6 2.6 0 0 0 6.6 22h10.8a2.6 2.6 0 0 0 2.6-2.6V6.2a2.6 2.6 0 0 0-2.6-2.6H16" />
          <path d="M8 11h8M8 15h4" />
        </>
      )}
      {props.id === "shelf" && (
        <>
          <rect x="2.5" y="2.5" width="19" height="19" rx="4.5" />
          <path d="M2.5 13.5h4.9c.85 0 1.5.7 1.9 1.45.4.8 1.2 1.55 2.7 1.55s2.3-.75 2.7-1.55c.4-.75 1.05-1.45 1.9-1.45h4.9" />
        </>
      )}
      {props.id === "shortcuts" && (
        <>
          <rect x="7.5" y="7.5" width="14" height="14" rx="3.8" />
          <path d="M7.5 16.5H6.2a3.7 3.7 0 0 1-3.7-3.7V6.2a3.7 3.7 0 0 1 3.7-3.7h6.6a3.7 3.7 0 0 1 3.7 3.7v1.3" />
        </>
      )}
      {props.id === "usage" && (
        <>
          <circle cx="12" cy="12" r="9.5" />
          <circle cx="12" cy="12" r="4.5" />
          <path d="M12 2.5V7.5M3.8 16.8l3.9-2.2M16.3 14.6l3.9 2.2" />
        </>
      )}
      {props.id === "system" && (
        <>
          <rect x="5" y="5" width="14" height="14" rx="3" />
          <rect x="9" y="9" width="6" height="6" rx="1" />
          <path d="M8 2v3M12 2v3M16 2v3M8 19v3M12 19v3M16 19v3M2 8h3M2 12h3M2 16h3M19 8h3M19 12h3M19 16h3" />
        </>
      )}
      {props.id === "todo" && (
        <>
          <path d="m3 5.8 1.7 1.7L7.6 3.9M11.5 5.7H21" />
          <path d="m3 12.3 1.7 1.7 2.9-3.6M11.5 12.2H21" />
          <rect x="3" y="16.5" width="4.6" height="4.6" rx="1.3" />
          <path d="M11.5 18.8H21" />
        </>
      )}
      {props.id === "notes" && (
        <>
          <path d="M14 2H6a3 3 0 0 0-3 3v14a3 3 0 0 0 3 3h12a3 3 0 0 0 3-3V9l-7-7Z" />
          <path d="M14 2v5a2 2 0 0 0 2 2h5M7 13h10M7 17h7" />
        </>
      )}
      {props.id === "inbox" && (
        <>
          <path d="M15.5 18a3.5 3.5 0 0 1-7 0" />
          <path d="M19.2 18H4.8a1.8 1.8 0 0 1-1.3-3l.6-.6c.56-.56.9-1.33.9-2.14V9.5a7 7 0 1 1 14 0v2.76c0 .81.34 1.58.9 2.14l.6.6a1.8 1.8 0 0 1-1.3 3Z" />
        </>
      )}
    </svg>
  );
}

export function SunIcon(props: { class?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      class={props.class ?? "h-4 w-4"}
    >
      <path d="M17 12C17 14.7614 14.7614 17 12 17C9.23858 17 7 14.7614 7 12C7 9.23858 9.23858 7 12 7C14.7614 7 17 9.23858 17 12Z" />
      <path d="M12 2C11.6227 2.33333 11.0945 3.2 12 4M12 20C12.3773 20.3333 12.9055 21.2 12 22M19.5 4.50271C18.9685 4.46982 17.9253 4.72293 18.0042 5.99847M5.49576 17.5C5.52865 18.0315 5.27555 19.0747 4 18.9958M5.00271 4.5C4.96979 5.03202 5.22315 6.0763 6.5 5.99729M18 17.5026C18.5315 17.4715 19.5747 17.7108 19.4958 18.9168M22 12C21.6667 11.6227 20.8 11.0945 20 12M4 11.5C3.66667 11.8773 2.8 12.4055 2 11.5" />
    </svg>
  );
}

export function MoonIcon(props: { class?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      class={props.class ?? "h-4 w-4"}
    >
      <path d="M21.5 14.0784C20.3003 14.7189 18.9301 15.0821 17.4751 15.0821C12.7491 15.0821 8.91792 11.2509 8.91792 6.52485C8.91792 5.06986 9.28105 3.69968 9.92163 2.5C5.66765 3.49698 2.5 7.31513 2.5 11.8731C2.5 17.1899 6.8101 21.5 12.1269 21.5C16.6849 21.5 20.503 18.3324 21.5 14.0784Z" />
    </svg>
  );
}

export function AppleIcon(props: { class?: string }) {
  return (
    <svg
      viewBox="3.5 2.5 16 19.8"
      fill="currentColor"
      aria-hidden="true"
      class={props.class ?? "h-[17px] w-auto"}
    >
      <path d="M15.22 5.86c.64-.78 1.07-1.87.95-2.96-.93.04-2.06.62-2.73 1.4-.58.68-1.1 1.77-.96 2.83 1.04.08 2.1-.5 2.74-1.27Zm2.46 6.37c-.03-2.17 1.77-3.21 1.85-3.26-1.01-1.48-2.58-1.68-3.14-1.72-1.34-.14-2.61.79-3.29.79-.68 0-1.73-.77-2.84-.75-1.46.02-2.81.85-3.56 2.16-1.52 2.64-.39 6.54 1.09 8.68.72 1.05 1.58 2.22 2.72 2.18 1.09-.04 1.51-.71 2.83-.71 1.32 0 1.7.71 2.85.69 1.17-.02 1.91-1.06 2.63-2.11.83-1.22 1.17-2.4 1.19-2.46-.02-.01-2.28-.88-2.33-3.48Z" />
    </svg>
  );
}

export function DownloadIcon(props: { class?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.9"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      class={props.class ?? "h-4 w-4"}
    >
      <path d="M12 4v11m0 0-4-4m4 4 4-4M5 19.5h14" />
    </svg>
  );
}
