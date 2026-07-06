import React from 'react';

/** A photo entry in the grid */
export interface Photo {
  /** Unique identifier */
  id: string;
  /** Image source URL */
  url: string;
  /** Whether the photo is currently checked */
  selected?: boolean;
}

/** Selectable photo grid for item photos (mirrors the photo picker in the sell flow) */
export interface PhotoGridProps {
  /** Photos to display */
  photos?: Photo[];
  /** Number of columns */
  columns?: 2 | 3 | 4;
  /** Enable tap-to-select */
  selectable?: boolean;
  /** Force the empty-state placeholder */
  emptyState?: boolean;
  onSelect?: (id: string) => void;
}

export function PhotoGrid({
  photos = [],
  columns = 3,
  selectable = false,
  emptyState,
  onSelect,
}: PhotoGridProps) {
  const isEmpty = emptyState || photos.length === 0;

  return (
    <div className={`wonni wonni-photogrid wonni-photogrid--${columns}col`}>
      {isEmpty ? (
        <div className="wonni-photogrid__empty">
          <span style={{ fontSize: '32px' }}>📷</span>
          <span style={{ fontSize: '14px', fontWeight: '500' }}>Add photos</span>
        </div>
      ) : (
        photos.map((photo) => (
          <div
            key={photo.id}
            className={`wonni-photogrid__item${photo.selected ? ' wonni-photogrid__item--selected' : ''}`}
            onClick={() => selectable && onSelect?.(photo.id)}
          >
            <img src={photo.url} alt="" />
            {selectable && photo.selected && (
              <div className="wonni-photogrid__item-check">✓</div>
            )}
          </div>
        ))
      )}
    </div>
  );
}
