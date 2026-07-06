import { AppPill } from '@wonni/design-system';

const dark = { padding: 16, background: '#1C1425', borderRadius: 20, display: 'inline-flex', flexDirection: 'column' as const, gap: 8 };

export const Spinner = () => (
  <div style={dark}>
    <AppPill label="Processing" sublabel="3 items" progress={-1} color="purple" />
  </div>
);

export const WithProgress = () => (
  <div style={dark}>
    <AppPill label="Publishing" sublabel="2 of 3 posted" progress={0.67} color="purple" />
  </div>
);

export const Colors = () => (
  <div style={dark}>
    <AppPill label="Processing" progress={-1}  color="purple"  />
    <AppPill label="Uploading"  progress={0.4} color="accent"  />
    <AppPill label="Published"  progress={1}   color="success" />
  </div>
);
