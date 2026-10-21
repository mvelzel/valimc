import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.locale.DeprecatedTranslationsInfo;
import net.minecraft.locale.Language;

/**
 * The server's English strings (VMC-010f), as `Language.loadDefault` builds them: `en_us.json`
 * from the jar with unsupported `%d`-style formats rewritten, then the deprecated renames and
 * removals. `OUT.json` maps every key to its text, keys sorted. The server console prints command
 * feedback through them.
 */
public class LanguageOracle {
  public static void main(String[] args) throws Exception {
    var strings = new HashMap<String, String>();
    try (var stream = Language.class.getResourceAsStream("/assets/minecraft/lang/en_us.json")) {
      Language.loadFromJson(stream, strings::put);
    }
    DeprecatedTranslationsInfo.loadFromDefaultResource().applyToMap(strings);
    var text = new StringBuilder("{\n");
    var keys = new ArrayList<>(new TreeSet<>(strings.keySet()));
    var gson = new GsonBuilder().disableHtmlEscaping().create();
    for (int i = 0; i < keys.size(); i++) {
      text.append("  ").append(gson.toJson(keys.get(i))).append(": ").append(gson.toJson(strings.get(keys.get(i))))
          .append(i + 1 < keys.size() ? ",\n" : "\n");
    }
    Files.writeString(Path.of(args[0]), text.append("}\n").toString());
    System.out.println("PASS: " + keys.size() + " English strings");
  }
}
