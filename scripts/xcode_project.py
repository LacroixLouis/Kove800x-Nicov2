"""Small dependency-free reader/writer for Xcode's OpenStep project dictionaries."""
import json
import re


class ProjectSyntaxError(ValueError):
    pass


def loads(text):
    position = 0

    def skip():
        nonlocal position
        while position < len(text):
            if text[position].isspace():
                position += 1
            elif text.startswith('//', position):
                end = text.find('\n', position)
                position = len(text) if end < 0 else end + 1
            elif text.startswith('/*', position):
                end = text.find('*/', position + 2)
                if end < 0:
                    raise ProjectSyntaxError('Unterminated project comment')
                position = end + 2
            else:
                break

    def consume(token):
        nonlocal position
        skip()
        if not text.startswith(token, position):
            raise ProjectSyntaxError('Expected %r at %d' % (token, position))
        position += len(token)

    def value():
        nonlocal position
        skip()
        if position >= len(text):
            raise ProjectSyntaxError('Unexpected end of project')
        if text[position] == '{':
            position += 1
            result = {}
            while True:
                skip()
                if position < len(text) and text[position] == '}':
                    position += 1
                    return result
                key = value()
                if not isinstance(key, str) or key in result:
                    raise ProjectSyntaxError('Invalid or duplicate project key')
                consume('=')
                result[key] = value()
                consume(';')
        if text[position] == '(':
            position += 1
            result = []
            while True:
                skip()
                if position < len(text) and text[position] == ')':
                    position += 1
                    return result
                result.append(value())
                skip()
                if position < len(text) and text[position] == ',':
                    position += 1
                elif position >= len(text) or text[position] != ')':
                    raise ProjectSyntaxError('Expected array separator')
        if text[position] == '"':
            position += 1
            result = []
            while position < len(text):
                char = text[position]
                position += 1
                if char == '"':
                    return ''.join(result)
                if char == '\\':
                    if position >= len(text):
                        break
                    char = text[position]
                    position += 1
                    escapes = {'n': '\n', 'r': '\r', 't': '\t', 'b': '\b', 'f': '\f'}
                    if char in ('U', 'u'):
                        raw = text[position:position + 4]
                        if not re.fullmatch('[0-9a-fA-F]{4}', raw):
                            raise ProjectSyntaxError('Invalid Unicode escape')
                        result.append(chr(int(raw, 16)))
                        position += 4
                    elif char != '\n':
                        result.append(escapes.get(char, char))
                else:
                    result.append(char)
            raise ProjectSyntaxError('Unterminated project string')
        start = position
        while position < len(text) and not text[position].isspace() and text[position] not in '{}()=;,':
            if text.startswith('/*', position) or text.startswith('//', position):
                break
            position += 1
        if start == position:
            raise ProjectSyntaxError('Invalid project token at %d' % position)
        return text[start:position]

    result = value()
    skip()
    if position != len(text):
        raise ProjectSyntaxError('Trailing project data')
    return result


def dumps(project):
    def scalar(value):
        value = str(value)
        return value if re.fullmatch(r'[A-Za-z0-9_./+\-]+', value) else json.dumps(value, ensure_ascii=False)

    def emit(value, level=0):
        tab = '\t' * level
        if isinstance(value, dict):
            return '{\n' + ''.join('\t' * (level + 1) + scalar(k) + ' = ' + emit(v, level + 1) + ';\n'
                                   for k, v in value.items()) + tab + '}'
        if isinstance(value, list):
            return '(\n' + ''.join('\t' * (level + 1) + emit(v, level + 1) + ',\n' for v in value) + tab + ')'
        return scalar(value)

    return '// !$*UTF8*$!\n' + emit(project) + '\n'
