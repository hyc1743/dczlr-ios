// Find and list all references to given addresses.
//@category PortLab
import ghidra.app.script.GhidraScript;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceManager;
import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;

public class FindReferences extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2) throw new IllegalArgumentException("output file and target addresses required");
        File out = new File(args[0]);
        if (!out.isAbsolute()) throw new IllegalArgumentException("absolute output required");
        try (PrintWriter writer = new PrintWriter(new FileWriter(out, false))) {
            writer.println("target\tfrom\ttype");
            ReferenceManager manager = currentProgram.getReferenceManager();
            for (int i = 1; i < args.length; ++i) {
                var target = toAddr(args[i]);
                for (Reference reference : manager.getReferencesTo(target))
                    writer.printf("%s\t%s\t%s%n", args[i], reference.getFromAddress(), reference.getReferenceType());
            }
        }
    }
}
