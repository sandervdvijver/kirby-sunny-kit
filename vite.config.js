import kirby from 'vite-plugin-kirby'

export default ({ mode }) => ({
  base: mode === 'development' ? '/' : '/assets/bundled/',
  build: {
    outDir: 'assets/bundled',
    rollupOptions: {
      input: 'index.js',
      output: {
        entryFileNames: '[name]-[hash].js',
        assetFileNames: '[name]-[hash][extname]',
        inlineDynamicImports: true
      }
    },
  },
  plugins: [
    kirby({
      watch: [
        'site/(templates|snippets|controllers|models|layouts|blocks)/**/*.php',
        'content/**/*',
      ],
    }),
  ],
})