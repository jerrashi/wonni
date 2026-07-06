import React from 'react';

const PLATFORM_LABELS: Record<string, string> = {
  wonni: 'Wonni', ebay: 'eBay', etsy: 'Etsy', mercari: 'Mercari', facebook: 'Facebook',
};
const PLATFORM_EMOJI: Record<string, string> = {
  wonni: '⭕', ebay: '🛒', etsy: '🌿', mercari: '🛍️', facebook: '👥',
};
const STATUS_LABELS: Record<string, string> = {
  pending: 'Pending', posted: 'Posted', failed: 'Failed', manual: 'Manual',
};

/** Badge showing a single platform's cross-post status */
export interface CrossPostBadgeProps {
  /** The marketplace platform */
  platform: 'wonni' | 'ebay' | 'etsy' | 'mercari' | 'facebook';
  /** Current cross-post status */
  status?: 'pending' | 'posted' | 'failed' | 'manual';
  /** Show the platform name alongside status */
  showLabel?: boolean;
}

export function CrossPostBadge({ platform, status = 'pending', showLabel = true }: CrossPostBadgeProps) {
  return (
    <span className={`wonni wonni-xbadge wonni-xbadge--${status}`}>
      <span className="wonni-xbadge__dot" />
      <span>{PLATFORM_EMOJI[platform]}</span>
      {showLabel && `${PLATFORM_LABELS[platform]} · ${STATUS_LABELS[status]}`}
    </span>
  );
}
