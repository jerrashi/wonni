import { useEffect, useState } from "react";
import { collection, onSnapshot, query, where } from "firebase/firestore";
import { auth, db, callFunction } from "../firebase";

/** Products with more active variants than this post as a BACKGROUND job
 *  (`startPostJob`): a big one is split across several eBay / Etsy listings and
 *  can outlast a single callable. Smaller ones keep the direct call. */
export const BACKGROUND_POST_VARIANT_THRESHOLD = 25;

export function needsBackgroundPost(product) {
  const variants = Array.isArray(product?.variants) ? product.variants : [];
  return variants.filter((v) => v && v.active !== false).length > BACKGROUND_POST_VARIANT_THRESHOLD;
}

/** Start (or join) the background job for a product on "ebay" | "etsy". */
export async function startPostJob(productId, platform) {
  const { data } = await callFunction("startPostJob")({ productId, platform });
  return data; // { jobId, alreadyRunning }
}

const RUNNING = ["queued", "running", "partial"];

/** Latest background job per platform for one product, live. {ebay?, etsy?} */
export function usePostJobs(productId) {
  const [jobs, setJobs] = useState({});
  useEffect(() => {
    const uid = auth.currentUser?.uid;
    if (!uid || !productId) return undefined;
    const q = query(collection(db, "postJobs"), where("userId", "==", uid), where("productId", "==", productId));
    return onSnapshot(q, (snap) => {
      const latest = {};
      for (const d of snap.docs) {
        const j = { id: d.id, ...d.data() };
        const ms = j.createdAt?.toMillis?.() ?? 0;
        if (!latest[j.platform] || ms >= (latest[j.platform].createdAt?.toMillis?.() ?? 0)) latest[j.platform] = j;
      }
      setJobs(latest);
    }, (err) => console.warn("postJobs listener:", err.message));
  }, [productId]);
  return jobs;
}

/** A job the UI should show: still going, or the last attempt failed. */
export function visibleJob(job) {
  if (!job) return null;
  return RUNNING.includes(job.status) || job.status === "failed" ? job : null;
}
