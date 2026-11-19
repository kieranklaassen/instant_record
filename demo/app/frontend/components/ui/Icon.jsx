// The demo's line icons, by name, on one 24-unit grid.
const PATHS = {
  mail: <><rect x="3" y="5" width="18" height="14" rx="3" /><path d="M3.5 7.5 12 13l8.5-5.5" /></>,
  compose: <><path d="M12 20h9" /><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z" /></>,
  inbox: <><path d="M3 13h5l1.5 3h5L16 13h5" /><path d="M5.5 5h13L21 13v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-5Z" /></>,
  incoming: <><path d="M12 4v11" /><path d="m7 10 5 5 5-5" /><path d="M5 20h14" /></>,
  check: <path d="m5 12 4 4L19 6" />,
  archive: <><rect x="3" y="4" width="18" height="5" rx="1.5" /><path d="M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9" /><path d="M10 13h4" /></>,
  reply: <><path d="m9 7-5 5 5 5" /><path d="M4 12h10a6 6 0 0 1 6 6v1" /></>,
  unread: <><path d="M21 11v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h9" /><path d="m3.5 7.5 8.5 5.5 3-2" /><circle cx="19" cy="6" r="2.5" fill="currentColor" stroke="none" /></>,
  read: <><path d="M3 10.5 12 5l9 5.5V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" /><path d="m3.5 11 8.5 5 8.5-5" /></>,
  undo: <><path d="M9 14 4 9l5-5" /><path d="M4 9h10a6 6 0 0 1 0 12h-3" /></>,
  close: <><path d="M6 6l12 12" /><path d="M18 6 6 18" /></>,
  back: <><path d="m11 6-6 6 6 6" /><path d="M5 12h14" /></>,
}

export default function Icon({ name, size = 16 }) {
  return (
    <svg className="ui-icon" aria-hidden="true" width={size} height={size} viewBox="0 0 24 24" fill="none"
      stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">{PATHS[name]}</svg>
  )
}
