# SwiftUI views

Ruby picks the view and hands it props, the way `render inertia:` hands props to a React page. The view is yours, in SwiftUI.

## Declare what it takes

```ruby
# app/screens/product_screen.rb
class ProductScreen < InstantRecord::Native::Screen
  contract "ProductView" do |c|
    c.string :name
    c.int :stock
    c.action :buy
  end

  def body
    product = Product.find(param("id"))
    swift "ProductView" do
      prop "name", product.name
      number "stock", product.stock
    end
  end

  def perform(action, args, values)
    Product.find(param("id")).buy! if action == "buy"
  end
end
```

The contract is optional. With one, Ruby checks the props, and the build writes Swift types for them.

## Write the view

With the contract's types:

```sh
SWIFT_OUT=native/ios/Shop/Shop/InstantRecordContracts.swift bin/rails "instant_record:native[iphonesimulator]"
```

```swift
// native/ios/Shop/Shop/ProductView.swift
import InstantRecordNative
import SwiftUI

struct ProductView: View {
    let props: ProductViewProps
    let actions: TypedActions<ProductViewAction>

    var body: some View {
        Text(props.name)
        Button("Buy") { actions.send(.buy) }
    }
}
```

Register it in `ShopApp.swift`, in `register`:

```swift
views.register(ProductViewProps.self) { props, actions in ProductView(props: props, actions: actions) }
```

Then run the generator again with `--force`, which adds the new files to the Xcode project.

Without a contract, read props by name:

```swift
struct ProductView: View {
    let props: Props
    let actions: Actions

    var body: some View {
        Text(props["name"])
        Button("Buy") { actions.perform("buy") }
    }
}

views.register("ProductView") { props, actions in ProductView(props: props, actions: actions) }
```

| In Ruby | In Swift |
|---|---|
| `prop "name", "Tea"` | `props["name"]` |
| `flag "saved", true` | `props.bool("saved")` |
| `number "stock", 3` | `props.int("stock")` |
| `decimal "score", 4.5` | `props.double("score")` |
| `time "sent", entry.created_at.utc.iso8601(6)` | `props.date("sent")` |
| `props("lines") { record { ... } }` | `props.list("lines")` |

## A view with no Ruby screen

A tab or a route in `config/ruby_native.yml` can name a view directly. It is then given the address's params, all strings, and has no Ruby to send actions to. See [Mixing the three](mixing.md).
