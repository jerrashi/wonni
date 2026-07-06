import React from 'react';

/** Inline badge indicating AI-generated or AI-edited content (matches the ✦ sparkles in the iOS app) */
export interface AIBadgeProps {
  /** Badge label */
  label?: 'AI identified' | 'AI edited' | 'AI priced' | 'AI';
  /** Filled (solid background) or outline */
  variant?: 'filled' | 'outline';
}

export function AIBadge({ label = 'AI identified', variant = 'filled' }: AIBadgeProps) {
  return (
    <span className={`wonni wonni-ai-badge wonni-ai-badge--${variant}`}>
      <span>✦</span>
      {label}
    </span>
  );
}
