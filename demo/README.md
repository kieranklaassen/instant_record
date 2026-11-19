# InstantRecord demos

```sh
bin/rails db:prepare
bin/rails server
```

Every demo is Hotwire with no build step, except the Inbox, which is an
Inertia page in React (`app/frontend`), built on the gem's own package in
`../frontend`. Its bundle is built by Vite into
`app/assets/builds/inbox.js`:

```sh
npm install
npm run build   # once, or `npm run dev` to rebuild on change
npm test        # the keyboard hook's unit tests
```

`bin/rails test` and `bin/rails assets:precompile` build it first.
