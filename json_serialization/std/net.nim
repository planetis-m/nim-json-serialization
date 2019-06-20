import std/net, ../../json_serialization.nim
export json_serialization

proc writeValue*(writer: var JsonWriter, value: Port) =
  writeValue(writer, uint16 value)

proc readValue*(reader: var JsonReader, value: var Port) =
  value = Port reader.readValue(uint16)
