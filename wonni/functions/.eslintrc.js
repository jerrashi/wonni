module.exports = {
  env: {
    es2022: true,
    node: true,
  },
  extends: ["eslint:recommended"],
  parserOptions: {
    ecmaVersion: 2022,
  },
  rules: {
    "no-unused-vars": ["warn", {argsIgnorePattern: "^_"}],
    "no-console": "off", // Cloud Functions use console for Cloud Logging
  },
  ignorePatterns: ["node_modules/", "tests/"],
};
