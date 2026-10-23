// Static incoming references to explicitly supplied addresses; no target execution.
//@category PortLab
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Reference;
import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;

public class ExportAddressReferences extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2) throw new IllegalArgumentException("absolute output file and addresses required");
        File out = new File(args[0]);
        if (!out.isAbsolute()) throw new IllegalArgumentException("absolute output file required");
        try (PrintWriter writer = new PrintWriter(new FileWriter(out, false))) {
            writer.println("target\tfrom\tfunction\ttype");
            for (int i = 1; i < args.length; ++i) {
                Address address = toAddr(args[i]);
                for (Reference reference : getReferencesTo(address)) {
                    Function function = getFunctionContaining(reference.getFromAddress());
                    writer.printf("%s\t%s\t%s\t%s%n", address, reference.getFromAddress(),
                        function == null ? "unknown" : function.getEntryPoint().toString(), reference.getReferenceType());
                }
            }
        }
    }
}
