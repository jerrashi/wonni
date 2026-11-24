/**
 * contracts/aliexpress.js — AliExpress restock orders (functions/purchase_orders.js).
 * Model A: AliExpress ships to the seller; "received" adds the units to stock.
 */

const { z } = require("zod");
const { ProductIdSchema } = require("./_shared");

const RestockAddressSchema = z.object({
  fullName: z.string().min(1),
  phone: z.string().min(1),
  line1: z.string().min(1),
  line2: z.string().nullish(),
  city: z.string().min(1),
  state: z.string().min(1),
  zip: z.string().min(1),
  country: z.string().default("US"),
});

const PurchaseOrderStatusSchema = z.enum(["placed", "paid", "shipped", "delivered", "received", "cancelled"]);

module.exports = {
  contracts: [
    {
      name: "aliexpressCreateRestockOrder",
      summary: "Place an (unpaid) AliExpress order for more stock, shipped to the seller's address.",
      request: z.object({
        productId: ProductIdSchema,
        /** Required when the product has variants: which one to reorder. */
        variantSku: z.string().nullish(),
        quantity: z.number().int().min(1).max(100),
        address: RestockAddressSchema,
      }),
      response: z.object({ purchaseOrderId: z.string(), aeOrderIds: z.array(z.string()), status: PurchaseOrderStatusSchema }),
    },
    {
      name: "syncPurchaseOrders",
      summary: "Refresh status + tracking of open restock orders from AliExpress.",
      request: z.object({}).passthrough(),
      response: z.object({ updated: z.number().int(), failed: z.number().int() }),
    },
    {
      name: "markPurchaseOrderReceived",
      summary: "Add a restock order's units to stock (once) and push the new stock to every live platform.",
      request: z.object({
        purchaseOrderId: z.string().min(1),
        /** How many arrived; defaults to the ordered quantity. */
        quantity: z.number().int().min(0).max(100).nullish(),
      }),
      response: z.object({ success: z.literal(true), added: z.number().int(), newQuantity: z.number().nullable() }),
    },
  ],
};
