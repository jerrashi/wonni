import React from 'react';

type Platform   = 'wonni' | 'ebay' | 'etsy' | 'mercari' | 'facebook';
type XStatus    = 'pending' | 'posted' | 'failed' | 'manual';
type CardStatus = 'draft' | 'processing' | 'active' | 'sold' | 'sold_out';

const STATUS_STYLE: Record<CardStatus, { label: string; color: string; bg: string }> = {
  draft:      { label: 'Draft',        color: '#6B6180', bg: '#F3F0FF' },
  processing: { label: 'Processing…',  color: '#7C3AED', bg: '#EDE9FF' },
  active:     { label: 'Active',       color: '#065F46', bg: '#D1FAE5' },
  sold:       { label: 'Sold',         color: '#991B1B', bg: '#FEE2E2' },
  sold_out:   { label: 'Sold Out',     color: '#92400E', bg: '#FEF3C7' },
};

const PLATFORM_EMOJI: Record<Platform, string> = {
  wonni: '⭕', ebay: '🛒', etsy: '🌿', mercari: '🛍️', facebook: '👥',
};

/** Item listing card used in the sell flow overview and listings grid */
export interface ListingCardProps {
  /** Item title */
  title: string;
  /** Price in US dollars */
  price: number;
  /** Thumbnail image URL */
  imageUrl?: string;
  /** Listing lifecycle state */
  status?: CardStatus;
  /** Cross-post state per platform */
  crossPostPlatforms?: Array<{ platform: Platform; status: XStatus }>;
  /** True when the listing has AI-generated title, description, or price */
  hasAIContent?: boolean;
  /** Renders a checkmark overlay (multi-select mode) */
  isSelected?: boolean;
  onSelect?: () => void;
}

export function ListingCard({
  title,
  price,
  imageUrl,
  status,
  crossPostPlatforms,
  hasAIContent,
  isSelected,
  onSelect,
}: ListingCardProps) {
  const st = status ? STATUS_STYLE[status] : null;

  return (
    <div
      className={['wonni', 'wonni-listing-card', isSelected ? 'wonni-listing-card--selected' : ''].filter(Boolean).join(' ')}
      onClick={onSelect}
    >
      {imageUrl ? (
        <img className="wonni-listing-card__image" src={imageUrl} alt={title} />
      ) : (
        <div className="wonni-listing-card__image-placeholder">📷</div>
      )}

      {st && (
        <div className="wonni-listing-card__status">
          <span style={{
            display: 'inline-flex', alignItems: 'center',
            padding: '3px 8px', borderRadius: '9999px',
            fontSize: '11px', fontWeight: '600',
            background: st.bg, color: st.color,
          }}>
            {st.label}
          </span>
        </div>
      )}

      {isSelected !== undefined && (
        <div className={`wonni-listing-card__select${isSelected ? ' wonni-listing-card__select--checked' : ''}`}>
          {isSelected && <span style={{ color: 'white', fontSize: '12px', fontWeight: 700 }}>✓</span>}
        </div>
      )}

      <div className="wonni-listing-card__body">
        <div className="wonni-listing-card__title">{title}</div>
        <div className="wonni-listing-card__price">${price.toFixed(2)}</div>
        {(crossPostPlatforms?.length || hasAIContent) && (
          <div className="wonni-listing-card__badges">
            {hasAIContent && (
              <span style={{
                display: 'inline-flex', alignItems: 'center', gap: '4px',
                padding: '2px 7px', borderRadius: '9999px',
                fontSize: '11px', fontWeight: '600',
                background: '#EDE9FF', color: '#6D28D9',
              }}>
                ✦ AI
              </span>
            )}
            {crossPostPlatforms?.map(({ platform }) => (
              <span key={platform} style={{ fontSize: '14px' }} title={platform}>
                {PLATFORM_EMOJI[platform]}
              </span>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
