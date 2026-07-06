import { CrossPostStatusCard } from '@wonni/design-system';

const img = (color: string) =>
  `data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'><rect width='200' height='200' fill='${encodeURIComponent(color)}'/></svg>`;

export const AllStatuses = () => (
  <div style={{ width: 340 }}>
    <CrossPostStatusCard
      title="Vintage Levi's 501 Jeans — 32x30 Dark Wash"
      price={45.00}
      imageUrl={img('#C4B5FD')}
      platforms={[
        { platform: 'wonni',    status: 'posted'  },
        { platform: 'ebay',     status: 'posted'  },
        { platform: 'etsy',     status: 'pending' },
        { platform: 'mercari',  status: 'manual'  },
        { platform: 'facebook', status: 'failed'  },
      ]}
    />
  </div>
);

export const AllPosted = () => (
  <div style={{ width: 340 }}>
    <CrossPostStatusCard
      title="Nike Air Max '95 — Men's Size 10"
      price={89.00}
      imageUrl={img('#A78BFA')}
      platforms={[
        { platform: 'wonni',   status: 'posted' },
        { platform: 'ebay',    status: 'posted' },
        { platform: 'mercari', status: 'posted' },
      ]}
    />
  </div>
);
