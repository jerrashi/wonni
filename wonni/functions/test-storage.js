const admin = require("firebase-admin");
admin.initializeApp({
  projectId: "wonni-app",
  storageBucket: "wonni-app.firebasestorage.app"
});
const bucket = admin.storage().bucket();
bucket.getFiles({ prefix: "users/vKZZ83xRQOU9ghkNIN7XSl18dIS2/" }).then(data => {
  const files = data[0];
  console.log("Found files:");
  files.forEach(f => console.log(f.name));
}).catch(console.error);
