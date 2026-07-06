import { Sheet, Button, PlatformToggle } from '@wonni/design-system';

export const PlatformSelection = () => (
  <Sheet title="Publish listing" subtitle="Choose where to post this item">
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <PlatformToggle platform="ebay"     enabled={true}  connected={true} />
      <PlatformToggle platform="etsy"     enabled={false} connected={true} />
      <PlatformToggle platform="mercari"  enabled={true}  connected={true} />
      <PlatformToggle platform="facebook" enabled={false} connected={false} />
    </div>
  </Sheet>
);

export const ReviewActions = () => (
  <Sheet title="Ready to publish?" subtitle="Your AI-generated listing looks good">
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
      <Button variant="primary"     label="Publish to all platforms" fullWidth />
      <Button variant="secondary"   label="Edit listing first"        fullWidth />
      <Button variant="ghost"       label="Cancel"                    fullWidth />
    </div>
  </Sheet>
);
