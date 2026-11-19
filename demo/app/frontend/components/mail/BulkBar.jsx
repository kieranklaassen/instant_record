import IconButton from "../ui/IconButton"

// What the list header becomes while rows are selected. It is the header's
// height, so no row moves when it comes and goes.
export default function BulkBar({ count, keys, onArchive, onRead, onUnread, onClear }) {
  return (
    <header className="mail-bulk">
      <span className="mail-bulk-count" role="status">{count} selected</span>
      <div className="mail-bulk-actions">
        <IconButton icon="archive" chord={keys.archive} onClick={onArchive}>Archive</IconButton>
        <IconButton icon="read" title="Mark read" aria-label="Mark read" chord={keys.read} onClick={onRead}>Read</IconButton>
        <IconButton icon="unread" title="Mark unread" aria-label="Mark unread" chord={keys.unread} onClick={onUnread}>Unread</IconButton>
        <IconButton icon="close" title="Clear the selection" aria-label="Clear the selection" chord={keys.back} onClick={onClear} />
      </div>
    </header>
  )
}
