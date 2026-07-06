import { Button } from '@wonni/design-system';

export const Variants = () => (
  <div style={{ display: 'flex', flexDirection: 'column', gap: 10, padding: 16, width: 240 }}>
    <Button variant="primary"     label="Publish Listing" />
    <Button variant="secondary"   label="Save Draft" />
    <Button variant="ghost"       label="Cancel" />
    <Button variant="destructive" label="Delete Listing" />
  </div>
);

export const Sizes = () => (
  <div style={{ display: 'flex', flexDirection: 'column', gap: 10, padding: 16, alignItems: 'flex-start' }}>
    <Button size="sm" label="Small button" />
    <Button size="md" label="Medium button" />
    <Button size="lg" label="Large button" icon="✦" />
  </div>
);

export const States = () => (
  <div style={{ display: 'flex', flexDirection: 'column', gap: 10, padding: 16, width: 240 }}>
    <Button variant="primary" label="Publishing…" loading />
    <Button variant="primary" label="Unavailable" disabled />
    <Button variant="primary" label="Publish to 3 platforms" icon="🚀" fullWidth />
  </div>
);
