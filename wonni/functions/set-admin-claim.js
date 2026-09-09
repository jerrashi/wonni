const admin = require("firebase-admin");
const key = require("./service-account-key.json");
admin.initializeApp({ credential: admin.credential.cert(key) });
admin.auth()
  .setCustomUserClaims("vKZZ83xRQOU9ghkNIN7XSl18dIS2", { admin: true })
  .then(() => { console.log("Done — sign out and back in to refresh the token."); process.exit(0); })
  .catch(err => { console.error(err); process.exit(1); });
