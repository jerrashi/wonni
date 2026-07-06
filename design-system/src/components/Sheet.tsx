import React from 'react';

/** iOS-style bottom sheet container (mirrors the modal sheets in the sell flow) */
export interface SheetProps {
  /** Sheet title */
  title?: string;
  /** Subtitle displayed below the title */
  subtitle?: string;
  /** Sheet body content */
  children?: React.ReactNode;
  /** Show the iOS drag handle at the top */
  showDragHandle?: boolean;
  /** Remove body padding — for edge-to-edge content like lists and grids */
  noPadding?: boolean;
}

export function Sheet({ title, subtitle, children, showDragHandle = true, noPadding = false }: SheetProps) {
  return (
    <div className="wonni wonni-sheet">
      {showDragHandle && <div className="wonni-sheet__handle" />}
      {(title || subtitle) && (
        <div className="wonni-sheet__header">
          {title    && <div className="wonni-sheet__title">{title}</div>}
          {subtitle && <div className="wonni-sheet__subtitle">{subtitle}</div>}
        </div>
      )}
      <div className={`wonni-sheet__body${noPadding ? ' wonni-sheet__body--no-padding' : ''}`}>
        {children}
      </div>
    </div>
  );
}
