import React from 'react';

type TabId = 'home' | 'camera' | 'search' | 'inbox' | 'profile';

interface Tab { id: TabId; label: string; icon: string; isCamera?: boolean }

const TABS: Tab[] = [
  { id: 'home',    label: 'Home',    icon: '🏠' },
  { id: 'camera',  label: '',        icon: '📷', isCamera: true },
  { id: 'search',  label: 'Search',  icon: '🔍' },
  { id: 'inbox',   label: 'Inbox',   icon: '💬' },
  { id: 'profile', label: 'Profile', icon: '👤' },
];

/** iOS-style bottom navigation tab bar for Wonni's 5-tab layout */
export interface WonniTabBarProps {
  /** Currently active tab */
  activeTab?: TabId;
  /** Number of unread messages to show on the Inbox tab */
  pendingBadgeCount?: number;
  onTabChange?: (tab: TabId) => void;
}

export function WonniTabBar({ activeTab = 'home', pendingBadgeCount, onTabChange }: WonniTabBarProps) {
  return (
    <div className="wonni wonni-tabbar">
      {TABS.map((tab) => {
        const isActive = activeTab === tab.id;
        const hasBadge = tab.id === 'inbox' && pendingBadgeCount && pendingBadgeCount > 0;

        return (
          <div
            key={tab.id}
            className={`wonni-tabbar__item${isActive && !tab.isCamera ? ' wonni-tabbar__item--active' : ''}`}
            onClick={() => onTabChange?.(tab.id)}
          >
            {tab.isCamera ? (
              <div className="wonni-tabbar__camera-btn">{tab.icon}</div>
            ) : (
              <>
                <div className="wonni-tabbar__item-icon">{tab.icon}</div>
                <div className="wonni-tabbar__item-label">{tab.label}</div>
              </>
            )}
            {hasBadge && (
              <div className="wonni-tabbar__badge">
                {pendingBadgeCount! > 9 ? '9+' : pendingBadgeCount}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}
