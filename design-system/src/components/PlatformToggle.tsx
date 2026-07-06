import React from 'react';

const CONFIG: Record<string, { name: string; emoji: string; bg: string }> = {
  ebay:     { name: 'eBay',                 emoji: '🛒', bg: '#FBBF24' },
  etsy:     { name: 'Etsy',                 emoji: '🌿', bg: '#F97316' },
  mercari:  { name: 'Mercari',              emoji: '🛍️', bg: '#EC4899' },
  facebook: { name: 'Facebook Marketplace', emoji: '👥', bg: '#3B82F6' },
};

/** Toggle row for enabling/disabling cross-posting to a marketplace */
export interface PlatformToggleProps {
  /** The marketplace platform */
  platform: 'ebay' | 'etsy' | 'mercari' | 'facebook';
  /** Whether cross-posting is enabled */
  enabled?: boolean;
  /** Whether the user has linked their account for this platform */
  connected?: boolean;
  onChange?: (enabled: boolean) => void;
}

export function PlatformToggle({ platform, enabled = false, connected = true, onChange }: PlatformToggleProps) {
  const cfg = CONFIG[platform];
  return (
    <div
      className={[
        'wonni wonni-platform-toggle',
        enabled ? 'wonni-platform-toggle--enabled' : '',
        !connected ? 'wonni-platform-toggle--disconnected' : '',
      ].filter(Boolean).join(' ')}
      onClick={() => connected && onChange?.(!enabled)}
    >
      <div className="wonni-platform-toggle__icon" style={{ background: `${cfg.bg}22` }}>
        {cfg.emoji}
      </div>
      <div className="wonni-platform-toggle__label">
        <div className="wonni-platform-toggle__name">{cfg.name}</div>
        <div className="wonni-platform-toggle__status">
          {connected
            ? enabled ? 'Will cross-post' : 'Skip this listing'
            : 'Not connected — tap to connect'}
        </div>
      </div>
      <div className={`wonni-platform-toggle__switch${enabled ? ' wonni-platform-toggle__switch--on' : ''}`}>
        <div className="wonni-platform-toggle__switch-thumb" />
      </div>
    </div>
  );
}
