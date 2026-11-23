import { useRef, useEffect, useState } from "react";

// ⋯ button + iOS-style context menu (styles: .overflow-trigger / .overflow-menu
// in index.css). items: [{ label, onClick, danger?, disabled? }]
export default function OverflowMenu({ items }) {
  const [open, setOpen] = useState(false);
  const menuRef = useRef(null);
  const buttonRef = useRef(null);

  useEffect(() => {
    if (!open) return;
    function handleClickOutside(e) {
      if (menuRef.current && !menuRef.current.contains(e.target) && !buttonRef.current?.contains(e.target)) {
        setOpen(false);
      }
    }
    function handleKey(e) { if (e.key === "Escape") setOpen(false); }
    document.addEventListener("mousedown", handleClickOutside);
    document.addEventListener("keydown", handleKey);
    return () => {
      document.removeEventListener("mousedown", handleClickOutside);
      document.removeEventListener("keydown", handleKey);
    };
  }, [open]);

  return (
    <div style={{ position: "relative" }}>
      <button
        ref={buttonRef}
        className="overflow-trigger"
        onClick={() => setOpen(!open)}
        aria-label="More options"
        aria-haspopup="menu"
        aria-expanded={open}
        title="More options"
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
          <circle cx="5" cy="12" r="2" /><circle cx="12" cy="12" r="2" /><circle cx="19" cy="12" r="2" />
        </svg>
      </button>
      {open && (
        <div ref={menuRef} className="overflow-menu" role="menu">
          {items.map((item, idx) => (
            <button
              key={idx}
              role="menuitem"
              className={item.danger ? "danger" : ""}
              onClick={() => {
                if (!item.disabled) {
                  item.onClick?.();
                  setOpen(false);
                }
              }}
              disabled={item.disabled}
            >
              {item.label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
