const js = require("@eslint/js");
const security = require("eslint-plugin-security");

module.exports = [
  js.configs.recommended,
  security.configs.recommended,
  {
    languageOptions: {
      ecmaVersion: 2021,
      globals: {
        require: "readonly",
        module: "readonly",
        exports: "readonly",
        __dirname: "readonly",
        __filename: "readonly",
        process: "readonly",
        console: "readonly",
      },
    },
    rules: {
      "no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
      "security/detect-object-injection": "error",
      "security/detect-non-literal-regexp": "error",
      "security/detect-unsafe-regex": "error",
      "security/detect-eval-with-expression": "error",
      "security/detect-pseudoRandomBytes": "error",
      "security/detect-possible-timing-attacks": "warn",
    },
  },
];
