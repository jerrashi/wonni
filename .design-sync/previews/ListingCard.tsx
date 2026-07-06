import { ListingCard } from '@wonni/design-system';

// Tiny colored SVG squares — no network needed
const img = (color: string) =>
  `data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' width='400' height='400'><rect width='400' height='400' fill='${encodeURIComponent(color)}'/></svg>`;

export const WithPhoto = () => (
  <div style={{ width: 180 }}>
    <ListingCard
      title="Vintage Levi's 501 Jeans — 32x30 Dark Wash"
      price={45.00}
      imageUrl={img('#C4B5FD')}
      status="active"
      hasAIContent={true}
      crossPostPlatforms={[
        { platform: 'ebay',    status: 'posted'  },
        { platform: 'mercari', status: 'pending' },
      ]}
    />
  </div>
);

export const Statuses = () => (
  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, width: 360 }}>
    <ListingCard title="Nike Air Max '95" price={89}  imageUrl={img('#A78BFA')} status="active"     hasAIContent />
    <ListingCard title="Leather Bag"      price={55}  imageUrl={img('#DDD6FE')} status="sold" />
    <ListingCard title="Retro Camera"     price={120} imageUrl={img('#EDE9FF')} status="processing" hasAIContent />
    <ListingCard title="Silk Scarf"       price={28}  imageUrl={img('#F5F3FF')} status="draft"      isSelected={true} />
  </div>
);

export const NoPhoto = () => (
  <div style={{ width: 180 }}>
    <ListingCard
      title="Mystery item — tap to add photos"
      price={0}
      status="draft"
    />
  </div>
);
