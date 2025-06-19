# HTTPSpec Specification

HTTPSpec is a specification format for describing HTTP requests and their expected responses, extending the familiar `.http` file format with a method for assertions. This enables automated testing and validation of HTTP APIs.

## 1. File Extension

Files should use the `.httpspec` extension.

## 2. Request Format

Each request block follows the standard `.http` file format:

```
### Optional comment or test name
<HTTP_METHOD> <URL> [HTTP_VERSION]
<Header-Name>: <Header-Value>
...

<Optional request body>

//# <assertions>
```

**Example:**
```
### Get user by ID
GET https://api.example.com/users/123
Authorization: Bearer {{token}}
Accept: application/json

//# status == 200
//# header["content-length"] = 2345
```

## 3. Variable Substitution

Variables can be defined and referenced using `{{variable}}` syntax.

**Example:**
```
@token = abc123
GET https://api.example.com/users/123
Authorization: Bearer {{token}}
```

## 4. Assertions

Assertions are specified in the final block of a request, and begin with `//#`.

**Syntax:**
```
//# status == 200
//# header["content-length"] = 2345
```

### 4.1 Assertion Types

- **Status Code:**  
    `status == <code>`
- **Header Value:**  
    `header["<Header-Name>"] == "<expected value>"`
- **JSON Body:**  
    `body.<json_path> == <expected value>`
- **Body Contains:**  
    `body contains "<substring>"`
- **Custom Expressions:**  
    Use JavaScript-like expressions for advanced checks.

**Example:**
```
GET https://api.example.com/users/123

//# status == 200
//# header["Content-Type"] == "application/json"
//# body.id == 123
//# body.name == "John Doe"
//# body.email contains "@example.com"
```

### 4.2 JSON Path

Use dot notation for JSON body assertions. Arrays can be accessed with `[index]`.

**Example:**
```
body.data[0].id == 1
```

## 5. Comments

Lines starting with `#` are comments and ignored by the parser.

## 6. Multiple Requests

Multiple request/assertion blocks can be included in a single file, separated by blank lines. This is intended to support the usecase of a setup/teardown type logic, as well as tests that model a series of requests/responses.

## 7. Example HTTPSpec File

```
@token = abc123

### Get user by ID
GET https://api.example.com/users/123
Authorization: Bearer {{token}}
Accept: application/json


//# status == 200
//# header["Content-Type"] == "application/json"
//# body.id == 123
//# body.email contains "@example.com"

### Create new user
POST https://api.example.com/users
Content-Type: application/json

{
    "name": "Alice"
}

//# status == 201
//# body.name == "Alice"
```

---

## 8. Extensibility

Future versions may support:
- More assertion types (e.g., regex, timeouts)
- Setup/teardown hooks
- Response variable extraction
- Non-JSON specific parsing (XML, etc.)