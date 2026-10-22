import io, sys
# 2.63.34: quita el reintento del emit cuando el compactador le borro el temporal (emit parado mas
# de 60 s). El rename falla con FileNotFoundError y el evento se pierde; test-journal-hueco.sh D)
# debe caer.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = "        except FileNotFoundError as e:"
n = s.count(viejo)
s = s.replace(viejo, "        except NotADirectoryError as e:")
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sust en el reintento del emit")
