struct TypedLoop {
 func accept(value: Float) {}
 func run() {
 for y: Float in [-1, 0, 1] {
 for x: Float in [-1, 0, 1] {
 accept(value: missingTypedValue)
 accept(value: y)
 }
 }
 }
}
