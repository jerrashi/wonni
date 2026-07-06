import React from 'react';

type Platform   = 'wonni' | 'ebay' | 'etsy' | 'mercari' | 'facebook';
type PostStatus = 'posted' | 'pending' | 'failed' | 'manual';

const PLATFORM_CFG: Record<Platform, { name: string; emoji: string; color: string }> = {
  wonni:    { name: 'Wonni',               emoji: '⭕', color: '#8B5CF6' },
  ebay:     { name: 'eBay',                emoji: '🛒', color: '#FBBF24' },
  etsy:     { name: 'Etsy',                emoji: '🌿', color: '#F97316' },
  mercari:  { name: 'Mercari',             emoji: '🛍️', color: '#EC4899' },
  facebook: { name: 'Facebook Marketplace',emoji: '👥', color: '#3B82F6' },
};

const STATUS_CFG: Record<PostStatus, { label: string; color: string; bg: string }> = {
  posted:  { label: 'Posted ✓',        color: '#065F46', bg: '#D1FAE5' },
  pending: { label: 'In progress…',    color: '#6D28D9', bg: '#EDE9FF' },
  failed:  { label: 'Failed',          color: '#991B1B', bg: '#FEE2E2' },
  manual:  { label: 'Manual required', color: '#92400E', bg: '#FEF3C7' },
};

/** A single platform entry in the cross-post result card */
export interface CrossPostPlatformEntry {
  /** Platform identifier */
  platform: Platform;
  /** Whether the post succeeded, is pending, failed, or requires manual action */
  status: PostStatus;
  /** Deep link to the platform listing (when posted) */
  url?: string;
}

/** Post-publish summary card showing cross-post status across all platforms (mirrors CrossPostStatusView) */
export interface CrossPostStatusCardProps {
  /** Item title */
  title: string;
  /** Item price in US dollars */
  price: number;
  /** Thumbnail URL */
  imageUrl?: string;
  /** Per-platform result list */
  platforms: CrossPostPlatformEntry[];
}

export function CrossPostStatusCard({ title, price, imageUrl, platforms }: CrossPostStatusCardProps) {
  return (
    <div className="wonni wonni-status-card">
      <div className="wonni-status-card__header">
        <div className="wonni-status-card__image">
          {imageUrl ? <img src={imageUrl} alt={title} style={{ width: '100%', height: '100%', objectFit: 'cover', borderRadius: '8px' }} /> : '📷'}
        </div>
        <div className="wonni-status-card__info">
          <div className="wonni-status-card__title">{title}</div>
          <div className="wonni-status-card__price">${price.toFixed(2)}</div>
        </div>
      </div>

      <div className="wonni-status-card__platforms">
        {platforms.map(({ platform, status }) => {
          const pc = PLATFORM_CFG[platform];
          const sc = STATUS_CFG[status];
          return (
            <div key={platform} className="wonni-status-card__platform-row">
              <div
                className="wonni-status-card__platform-icon"
                style={{ background: `${pc.color}1A` }}
              >
                {pc.emoji}
              </div>
              <div className="wonni-status-card__platform-name">{pc.name}</div>
              <span style={{
                display: 'inline-flex', alignItems: 'center',
                padding: '3px 10px', borderRadius: '9999px',
                fontSize: '11px', fontWeight: '600',
                background: sc.bg, color: sc.color,
              }}>
                {sc.label}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
