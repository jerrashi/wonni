import React from 'react';

/** Floating task pill shown above the tab bar (mirrors AppTaskQueue in the iOS app) */
export interface AppPillProps {
  /** Primary label — e.g. "Processing", "Publishing" */
  label: string;
  /** Optional secondary detail line */
  sublabel?: string;
  /**
   * Progress indicator:
   * - `-1` shows an indeterminate spinner
   * - `0–1` shows a filled progress ring
   */
  progress?: number;
  /** Background color */
  color?: 'purple' | 'accent' | 'success' | 'warning';
  onClick?: () => void;
}

export function AppPill({
  label,
  sublabel,
  progress = -1,
  color = 'purple',
  onClick,
}: AppPillProps) {
  const r = 9;
  const circumference = 2 * Math.PI * r;
  const isSpinner = progress < 0;
  const dashOffset = isSpinner ? circumference * 0.7 : circumference * (1 - Math.min(1, progress));

  return (
    <div
      className={`wonni wonni-pill wonni-pill--${color}`}
      onClick={onClick}
      role="button"
      tabIndex={0}
    >
      <div className="wonni-pill__icon">
        <svg width="24" height="24" viewBox="0 0 24 24" style={{ overflow: 'visible' }}>
          <circle cx="12" cy="12" r={r} fill="none" stroke="currentColor" strokeWidth="2.5" strokeOpacity="0.25" />
          <circle
            cx="12" cy="12" r={r}
            fill="none"
            stroke="currentColor"
            strokeWidth="2.5"
            strokeLinecap="round"
            strokeDasharray={circumference}
            strokeDashoffset={dashOffset}
            style={isSpinner
              ? { animation: 'wonni-spin 0.8s linear infinite', transformOrigin: '50% 50%' }
              : { transform: 'rotate(-90deg)', transformOrigin: '50% 50%', transition: 'stroke-dashoffset 0.5s cubic-bezier(0.4,0,0.2,1)' }
            }
          />
        </svg>
      </div>
      <div>
        <div className="wonni-pill__label">{label}</div>
        {sublabel && <div className="wonni-pill__sublabel">{sublabel}</div>}
      </div>
    </div>
  );
}
