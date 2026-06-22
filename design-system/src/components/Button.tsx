import React from 'react';

/** A Wonni action button — primary CTA, secondary, ghost, or destructive */
export interface ButtonProps {
  /** Visual style */
  variant?: 'primary' | 'secondary' | 'ghost' | 'destructive';
  /** Button size */
  size?: 'sm' | 'md' | 'lg';
  /** Label text */
  label: string;
  /** Disables interaction */
  disabled?: boolean;
  /** Replaces content with a loading spinner */
  loading?: boolean;
  /** Emoji or character displayed before the label */
  icon?: string;
  /** Stretch to fill container width */
  fullWidth?: boolean;
  onClick?: () => void;
}

export function Button({
  variant = 'primary',
  size = 'md',
  label,
  disabled = false,
  loading = false,
  icon,
  fullWidth = false,
  onClick,
}: ButtonProps) {
  return (
    <button
      className={['wonni', 'wonni-btn', `wonni-btn--${variant}`, `wonni-btn--${size}`].join(' ')}
      disabled={disabled || loading}
      onClick={onClick}
      style={fullWidth ? { width: '100%' } : undefined}
    >
      {loading ? (
        <span className="wonni-btn__spinner" />
      ) : (
        <>
          {icon && <span>{icon}</span>}
          {label}
        </>
      )}
    </button>
  );
}
