# Markdown Reader — Test Document

A quick **smoke test** of the _renderer_. Here is some `inline code`, a
[link to Anthropic](https://www.anthropic.com), and ~~struck text~~.

## Lists

- First item
- Second item with **bold**
  - Nested item
  - Another nested
- Third item

1. One
2. Two
3. Three

### Task list

- [x] Build the app
- [ ] Set as default
- [ ] Read all the things

## Blockquote

> This is a quote.
> It spans multiple lines.

## Code block

```python
def greet(name):
    # say hello
    message = "Hello, " + name + "!"
    return message

print(greet("world"))
```

```javascript
const x = 42;
function add(a, b) { return a + b; }  // a comment
```

## Table

| Feature      | Status | Notes            |
|--------------|:------:|------------------|
| Rendered view| ✅     | default          |
| Source view  | ✅     | syntax colored   |
| Live reload  | ✅     | watches the file |

## Horizontal rule

---

That's the end.
