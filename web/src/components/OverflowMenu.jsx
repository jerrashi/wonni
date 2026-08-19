import { useRef, useEffect, useState } from "react";

export default function OverflowMenu({ items }) {
  const [open, setOpen] = useState(false);
  const menuRef = useRef(null);
  const buttonRef = useRef(null);

  useEffect(() => {
    function handleClickOutside(e) {
      if (menuRef.current && !menuRef.current.contains(e.target) && !buttonRef.current?.contains(e.target)) {
        setOpen(false);
      }
    }
    if (open) {
      document.addEventListener("mousedown", handleClickOutside);
      return () => document.removeEventListener("mousedown", handleClickOutside);
    }
  }, [open]);

  return (
    <div style={{ position: "relative" }}>
      <button
        ref={buttonRef}
        className="btn btn-ghost"
        style={{ padding: "8px 10px", fontSize: 12 }}
        onClick={() => setOpen(!open)}
        title="More options"
      >
        ⋯
      </button>
      {open && (
        <div
          ref={menuRef}
          style={{
            position: "absolute",
            top: "100%",
            right: 0,
            marginTop: 4,
            background: "var(--surface)",
            border: "1px solid var(--border)",
            borderRadius: 6,
            minWidth: 160,
            zIndex: 100,
            boxShadow: "0 4px 8px rgba(0,0,0,0.3)",
          }}
        >
          {items.map((item, idx) => (
            <button
              key={idx}
              className="btn btn-ghost"
              style={{
                display: "block",
                width: "100%",
                textAlign: "left",
                padding: "8px 12px",
                fontSize: 12,
                borderRadius: 0,
                color: item.danger ? "var(--danger)" : "inherit",
                opacity: item.disabled ? 0.5 : 1,
                cursor: item.disabled ? "not-allowed" : "pointer",
                borderBottom: idx < items.length - 1 ? "1px solid var(--border)" : "none",
              }}
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
