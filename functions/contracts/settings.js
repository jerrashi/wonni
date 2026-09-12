/**
 * contracts/settings.js — per-user configuration callables.
 *
 * `sale_stages.js` owns the shape/validation of a stage list; this just
 * describes the wire contract for replacing it wholesale.
 */

const { z } = require("zod");
const { OkResponseSchema } = require("./_shared");

const SaleStageSchema = z.object({
  key: z.string().min(1).max(40),
  label: z.string().min(1).max(60),
  builtIn: z.boolean().default(false),
});

const UpdateSaleStagesRequestSchema = z.object({
  stages: z.array(SaleStageSchema).min(1).max(50),
});

module.exports = {
  SaleStageSchema,
  contracts: [
    {
      name: "updateSaleStages",
      summary: "Replace the user's sale-stage board/dropdown bucket list (kanban columns).",
      request: UpdateSaleStagesRequestSchema,
      response: OkResponseSchema,
    },
  ],
};
