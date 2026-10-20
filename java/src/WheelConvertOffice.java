import de.rototor.pdfbox.graphics2d.PdfBoxGraphics2D;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.contentstream.operator.color.*;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.PDPage;
import org.apache.pdfbox.pdmodel.PDPageContentStream;
import org.apache.pdfbox.pdmodel.common.PDRectangle;
import org.apache.pdfbox.pdmodel.font.PDFont;
import org.apache.pdfbox.pdmodel.graphics.form.PDFormXObject;
import org.apache.pdfbox.rendering.ImageType;
import org.apache.pdfbox.rendering.PDFRenderer;
import org.apache.pdfbox.text.PDFTextStripper;
import org.apache.pdfbox.text.TextPosition;
import org.apache.poi.sl.draw.Drawable;
import org.apache.poi.sl.usermodel.PictureData;
import org.apache.poi.sl.usermodel.Slide;
import org.apache.poi.sl.usermodel.SlideShow;
import org.apache.poi.sl.usermodel.SlideShowFactory;
import org.apache.poi.ss.usermodel.*;
import org.apache.poi.ss.util.CellRangeAddress;
import org.apache.poi.ss.util.WorkbookUtil;
import org.apache.poi.xslf.usermodel.XMLSlideShow;
import org.apache.poi.xslf.usermodel.XSLFPictureData;
import org.apache.poi.xslf.usermodel.XSLFPictureShape;
import org.apache.poi.xslf.usermodel.XSLFSlide;
import org.apache.poi.xssf.streaming.SXSSFWorkbook;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;

import javax.imageio.IIOImage;
import javax.imageio.ImageIO;
import javax.imageio.ImageWriteParam;
import javax.imageio.ImageWriter;
import javax.imageio.stream.ImageOutputStream;
import javax.xml.XMLConstants;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import java.awt.*;
import java.awt.geom.Rectangle2D;
import java.awt.image.BufferedImage;
import java.io.*;
import java.nio.charset.*;
import java.nio.file.*;
import java.text.DecimalFormat;
import java.text.DecimalFormatSymbols;
import java.time.*;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.List;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

/**
 * Office conversions for WheelConvert that need Apache POI and PDFBox.
 *
 * Protocol: arguments are a command plus paths. Progress goes to stdout as "PROGRESS:<0..1>",
 * every written file as "OUT:<absolute path>". Failures exit non-zero with a one-line message on stderr.
 */
public final class WheelConvertOffice {

    public static void main(String[] args) {
        try {
            if (args.length < 3) throw new UserError("Usage: WheelConvertOffice <command> <input> <output> [options]");
            Path in = Paths.get(args[1]).toAbsolutePath();
            Path out = Paths.get(args[2]).toAbsolutePath();
            if (!Files.isRegularFile(in)) throw new UserError("The source file could not be read.");
            switch (args[0]) {
                case "slides" -> slides(in, out, args.length > 3 ? args[3] : "pdf", args.length > 4 ? Float.parseFloat(args[4]) : 2f);
                case "pdf2pptx" -> pdfToPptx(in, out, args.length <= 3 || !args[3].equals("pages"));
                case "sheet" -> writeSheets(readSheets(in), out);
                case "sheet2html" -> writeHtml(readSheets(in), out, in.getFileName().toString());
                case "pdf2sheet" -> writeSheets(readPdfTables(in), out);
                default -> throw new UserError("Unknown command " + args[0]);
            }
            System.out.flush();
            System.exit(0);
        } catch (UserError e) {
            System.err.println(e.getMessage());
            System.exit(2);
        } catch (Throwable t) {
            String message = t.getMessage();
            System.err.println(t.getClass().getSimpleName() + (message == null ? "" : ": " + message.replace('\n', ' ')));
            System.exit(1);
        }
    }

    static final class UserError extends Exception {
        UserError(String message) { super(message); }
    }

    static void progress(double fraction) {
        System.out.println("PROGRESS:" + Math.max(0, Math.min(1, fraction)));
    }

    static void emit(Path path) {
        System.out.println("OUT:" + path.toAbsolutePath());
    }

    // MARK: - Slides

    static final Map<String, String> FONT_MAP = Map.of(
            "Calibri", "Helvetica Neue",
            "Calibri Light", "Helvetica Neue",
            "Cambria", "Georgia",
            "Segoe UI", "Helvetica Neue",
            "Aptos", "Helvetica Neue",
            "Aptos Display", "Helvetica Neue");

    static void configure(Graphics2D g) {
        g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
        g.setRenderingHint(RenderingHints.KEY_RENDERING, RenderingHints.VALUE_RENDER_QUALITY);
        g.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BICUBIC);
        g.setRenderingHint(RenderingHints.KEY_FRACTIONALMETRICS, RenderingHints.VALUE_FRACTIONALMETRICS_ON);
        g.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
        g.setRenderingHint(Drawable.FONT_MAP, FONT_MAP);
    }

    /** Renders every slide to one PDF (vector) or to numbered PNG/JPEG images inside {@code out}. */
    static void slides(Path in, Path out, String format, float scale) throws Exception {
        try (SlideShow<?, ?> show = SlideShowFactory.create(in.toFile(), null, true)) {
            List<? extends Slide<?, ?>> slides = show.getSlides();
            if (slides.isEmpty()) throw new UserError("The presentation has no slides.");
            Dimension size = show.getPageSize();
            if (size.width <= 0 || size.height <= 0) throw new UserError("The presentation has an invalid slide size.");
            if (format.equals("pdf")) {
                try (PDDocument pdf = new PDDocument()) {
                    for (int i = 0; i < slides.size(); i++) {
                        PDPage page = new PDPage(new PDRectangle(size.width, size.height));
                        pdf.addPage(page);
                        PdfBoxGraphics2D g = new PdfBoxGraphics2D(pdf, size.width, size.height);
                        configure(g);
                        slides.get(i).draw(g);
                        g.dispose();
                        PDFormXObject form = g.getXFormObject();
                        try (PDPageContentStream content = new PDPageContentStream(pdf, page)) {
                            content.drawForm(form);
                        }
                        progress((i + 1.0) / slides.size());
                    }
                    pdf.save(out.toFile());
                }
                emit(out);
                return;
            }
            boolean jpeg = format.equals("jpg");
            Files.createDirectories(out);
            int width = Math.round(size.width * scale), height = Math.round(size.height * scale);
            String base = stripExtension(in.getFileName().toString());
            for (int i = 0; i < slides.size(); i++) {
                BufferedImage image = new BufferedImage(width, height, jpeg ? BufferedImage.TYPE_INT_RGB : BufferedImage.TYPE_INT_ARGB);
                Graphics2D g = image.createGraphics();
                configure(g);
                if (jpeg) {
                    g.setPaint(java.awt.Color.WHITE);
                    g.fillRect(0, 0, width, height);
                }
                g.scale(scale, scale);
                slides.get(i).draw(g);
                g.dispose();
                Path file = out.resolve(base + " - Slide " + (i + 1) + (jpeg ? ".jpg" : ".png"));
                if (jpeg) writeJpeg(image, file, 0.92f); else ImageIO.write(image, "png", file.toFile());
                emit(file);
                progress((i + 1.0) / slides.size());
            }
        }
    }

    static void writeJpeg(BufferedImage image, Path file, float quality) throws IOException {
        ImageWriter writer = ImageIO.getImageWritersByFormatName("jpeg").next();
        ImageWriteParam param = writer.getDefaultWriteParam();
        param.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);
        param.setCompressionQuality(quality);
        try (ImageOutputStream stream = ImageIO.createImageOutputStream(file.toFile())) {
            writer.setOutput(stream);
            writer.write(null, new IIOImage(image, null, null), param);
        } finally {
            writer.dispose();
        }
    }

    /**
     * One slide per PDF page. With {@code editable}, upright text becomes real text boxes placed where
     * the PDF has it, over a picture of everything else on the page; otherwise the whole page is a
     * picture. Pictures are JPEG when that is much smaller (photos, scans) and PNG for crisp line art.
     */
    static void pdfToPptx(Path in, Path out, boolean editable) throws Exception {
        try (PDDocument pdf = Loader.loadPDF(in.toFile())) {
            int count = pdf.getNumberOfPages();
            if (count == 0) throw new UserError("This PDF has no pages.");
            PDRectangle first = pdf.getPage(0).getCropBox();
            Dimension slideSize = new Dimension(Math.max(1, Math.round(rotatedWidth(pdf.getPage(0), first))),
                    Math.max(1, Math.round(rotatedHeight(pdf.getPage(0), first))));
            PDFRenderer renderer = new PDFRenderer(pdf), textless = new TextlessRenderer(pdf);
            try (XMLSlideShow show = new XMLSlideShow()) {
                show.setPageSize(slideSize);
                for (int i = 0; i < count; i++) {
                    PDPage page = pdf.getPage(i);
                    // Rotated pages keep the picture: their text coordinates don't follow the rotation.
                    List<Glyph> glyphs = editable && page.getRotation() % 360 == 0 ? GlyphCollector.collect(pdf, i) : List.of();
                    float pageWidth = rotatedWidth(page, page.getCropBox()), pageHeight = rotatedHeight(page, page.getCropBox());
                    // 200 DPI, but no wider than 4096 pixels: poster-sized pages would otherwise make huge pictures.
                    float dpi = Math.min(200f, 4096f / (Math.max(pageWidth, pageHeight) / 72f));
                    BufferedImage image = (glyphs.isEmpty() ? renderer : textless).renderImageWithDPI(i, dpi, ImageType.RGB);
                    double fit = Math.min(slideSize.width / (double) pageWidth, slideSize.height / (double) pageHeight);
                    double left = (slideSize.width - pageWidth * fit) / 2, top = (slideSize.height - pageHeight * fit) / 2;
                    XSLFSlide slide = show.createSlide();
                    if (glyphs.isEmpty() || !isBlank(image)) {
                        boolean[] jpeg = {false};
                        byte[] bytes = pictureBytes(image, jpeg);
                        XSLFPictureData data = show.addPicture(bytes, jpeg[0] ? PictureData.PictureType.JPEG : PictureData.PictureType.PNG);
                        XSLFPictureShape picture = slide.createPicture(data);
                        picture.setAnchor(new Rectangle2D.Double(left, top, pageWidth * fit, pageHeight * fit));
                    }
                    for (List<Line> block : blocks(lines(glyphs))) addTextBox(slide, block, fit, left, top);
                    progress((i + 1.0) / count);
                }
                try (OutputStream stream = Files.newOutputStream(out)) {
                    show.write(stream);
                }
            }
        } catch (org.apache.pdfbox.pdmodel.encryption.InvalidPasswordException e) {
            throw new UserError("The PDF cannot be read or is password-protected.");
        }
        emit(out);
    }

    /** PNG for line art and text-free pages; JPEG when it's under half the size (photos, scans). */
    static byte[] pictureBytes(BufferedImage image, boolean[] jpeg) throws IOException {
        ByteArrayOutputStream png = new ByteArrayOutputStream();
        ImageIO.write(image, "png", png);
        ByteArrayOutputStream jpg = new ByteArrayOutputStream();
        ImageWriter writer = ImageIO.getImageWritersByFormatName("jpeg").next();
        ImageWriteParam param = writer.getDefaultWriteParam();
        param.setCompressionMode(ImageWriteParam.MODE_EXPLICIT);
        param.setCompressionQuality(0.85f);
        try (ImageOutputStream stream = ImageIO.createImageOutputStream(jpg)) {
            writer.setOutput(stream);
            writer.write(null, new IIOImage(image, null, null), param);
        } finally {
            writer.dispose();
        }
        jpeg[0] = jpg.size() * 2 < png.size();
        return jpeg[0] ? jpg.toByteArray() : png.toByteArray();
    }

    /** Nothing but white left once the text is lifted out. */
    static boolean isBlank(BufferedImage image) {
        for (int y = 0; y < image.getHeight(); y += 2) {
            for (int x = 0; x < image.getWidth(); x += 2) {
                int rgb = image.getRGB(x, y);
                if (((rgb >> 16) & 255) < 250 || ((rgb >> 8) & 255) < 250 || (rgb & 255) < 250) return false;
            }
        }
        return true;
    }

    /** A character the slide shows as text, in page points (origin top-left, y at the baseline). */
    record Glyph(String text, float x, float right, float y, float size, String font, boolean bold, boolean italic, int color) { }

    record Line(List<Glyph> glyphs) {
        float x() { return glyphs.get(0).x(); }
        float right() { return glyphs.get(glyphs.size() - 1).right(); }
        float y() { return glyphs.get(0).y(); }
        float size() { return (float) glyphs.stream().mapToDouble(Glyph::size).max().orElse(12); }
    }

    /**
     * Whether a glyph becomes slide text: upright, with a known character, in a font that isn't drawn
     * by its own procedures (Type 3). The collector and {@link TextlessRenderer} share this rule, so
     * every glyph ends up either in a text box or in the picture, never both or neither.
     */
    static boolean liftable(PDFont font, int code, org.apache.pdfbox.util.Matrix matrix) {
        if (font == null || font instanceof org.apache.pdfbox.pdmodel.font.PDType3Font) return false;
        if (Math.abs(matrix.getShearX()) > 0.001f || Math.abs(matrix.getShearY()) > 0.001f || matrix.getScaleX() <= 0 || matrix.getScaleY() <= 0) return false;
        String text;
        try { text = font.toUnicode(code); } catch (Exception e) { return false; }
        return text != null && !text.isEmpty() && !text.contains("\uFFFD") && text.codePoints().noneMatch(Character::isISOControl);
    }

    /** Renders a page without the glyphs that become text boxes. */
    static final class TextlessRenderer extends PDFRenderer {
        TextlessRenderer(PDDocument document) { super(document); }

        @Override
        protected org.apache.pdfbox.rendering.PageDrawer createPageDrawer(org.apache.pdfbox.rendering.PageDrawerParameters parameters) throws IOException {
            return new org.apache.pdfbox.rendering.PageDrawer(parameters) {
                @Override
                protected void showFontGlyph(org.apache.pdfbox.util.Matrix matrix, PDFont font, int code, org.apache.pdfbox.util.Vector displacement) throws IOException {
                    if (getGraphicsState().getTextState().getRenderingMode() == org.apache.pdfbox.pdmodel.graphics.state.RenderingMode.NEITHER
                            || !liftable(font, code, matrix)) {
                        super.showFontGlyph(matrix, font, code, displacement);
                    }
                }
            };
        }
    }

    /** Visible, liftable glyphs of one page with their font, size, style and color. */
    static final class GlyphCollector extends PDFTextStripper {
        final List<Glyph> glyphs = new ArrayList<>();
        final Map<String, String> families = new HashMap<>();

        GlyphCollector() throws IOException {
            // Text extraction ignores color operators; these keep the graphics state's colors current.
            for (var op : List.of(new SetStrokingColorSpace(this), new SetNonStrokingColorSpace(this), new SetStrokingColor(this), new SetNonStrokingColor(this),
                    new SetStrokingColorN(this), new SetNonStrokingColorN(this), new SetStrokingDeviceGrayColor(this), new SetNonStrokingDeviceGrayColor(this),
                    new SetStrokingDeviceRGBColor(this), new SetNonStrokingDeviceRGBColor(this), new SetStrokingDeviceCMYKColor(this), new SetNonStrokingDeviceCMYKColor(this))) {
                addOperator(op);
            }
        }

        static List<Glyph> collect(PDDocument pdf, int index) throws IOException {
            GlyphCollector collector = new GlyphCollector();
            collector.setStartPage(index + 1);
            collector.setEndPage(index + 1);
            collector.getText(pdf);
            return collector.glyphs;
        }

        @Override
        protected void processTextPosition(TextPosition text) {
            var state = getGraphicsState();
            // Invisible text (the OCR layer of a scan) stays out: the scan in the picture shows it.
            if (state.getTextState().getRenderingMode() == org.apache.pdfbox.pdmodel.graphics.state.RenderingMode.NEITHER) return;
            int[] codes = text.getCharacterCodes();
            if (codes == null || codes.length == 0 || !liftable(text.getFont(), codes[0], text.getTextMatrix())) return;
            String value = text.getUnicode();
            if (value == null || value.isEmpty()) return;
            float x = text.getXDirAdj(), y = text.getYDirAdj();
            // Fake bold draws a glyph twice, a hair apart: keep one.
            for (int j = glyphs.size() - 1; j >= Math.max(0, glyphs.size() - 4); j--) {
                Glyph g = glyphs.get(j);
                if (g.text().equals(value) && Math.abs(g.x() - x) < 1f && Math.abs(g.y() - y) < 1f) return;
            }
            PDFont font = text.getFont();
            String raw = font.getName() == null ? "" : font.getName();
            String name = raw.contains("+") ? raw.substring(raw.indexOf('+') + 1) : raw;
            String lower = name.toLowerCase(Locale.ROOT);
            var descriptor = font.getFontDescriptor();
            // Variable-font instances name their weight: ".SFNS-Regular_…_wght2BC0000" is weight 0x2BC = 700.
            var weight = java.util.regex.Pattern.compile("wght([0-9A-Fa-f]{5,8})").matcher(name);
            boolean bold = weight.find() ? Long.parseLong(weight.group(1), 16) / 65536 >= 600
                    : lower.contains("bold") || lower.contains("black") || lower.contains("heavy") || lower.contains("semibold")
                    || (descriptor != null && (descriptor.isForceBold() || descriptor.getFontWeight() >= 600));
            boolean italic = lower.contains("italic") || lower.contains("oblique") || (descriptor != null && descriptor.isItalic());
            int color = 0;
            try {
                var paint = state.getTextState().getRenderingMode().isFill() ? state.getNonStrokingColor() : state.getStrokingColor();
                color = paint.toRGB();
            } catch (Exception ignored) {
                // Patterns and unusual color spaces read as black.
            }
            // The rendering matrix includes the page transform, which getFontSizeInPt leaves out.
            float size = Math.abs(text.getTextMatrix().getScalingFactorY());
            String family = families.computeIfAbsent(raw, key -> family(name, descriptor != null && descriptor.isSerif(), descriptor != null && descriptor.isFixedPitch()));
            glyphs.add(new Glyph(value, x, x + text.getWidthDirAdj(), y, Math.max(1f, size), family, bold, italic, color));
        }
    }

    static Set<String> installedFamilies;

    /**
     * The font family for slide text: "TimesNewRomanPS-BoldMT" becomes "Times New Roman". Apple's
     * hidden system fonts (".SFNS…") and fonts this Mac doesn't have map to a close standard family.
     */
    static String family(String name, boolean serif, boolean fixed) {
        if (name.startsWith(".SF") || name.startsWith(".AppleSystemUIFont")) return "Helvetica Neue";
        if (name.startsWith(".LucidaGrande")) return "Lucida Grande";
        String base = name.replaceFirst("^\\.", "").split("[-,_]")[0].replaceAll("(PSMT|MT|PS)$", "");
        base = base.replaceAll("([a-z])([A-Z])", "$1 $2").trim();
        if (installedFamilies == null) {
            installedFamilies = new HashSet<>();
            for (String family : GraphicsEnvironment.getLocalGraphicsEnvironment().getAvailableFontFamilyNames()) installedFamilies.add(family.toLowerCase(Locale.ROOT));
        }
        if (!base.isEmpty() && installedFamilies.contains(base.toLowerCase(Locale.ROOT))) return base;
        String lower = name.toLowerCase(Locale.ROOT);
        if (fixed || lower.contains("mono") || lower.contains("courier") || lower.contains("code")) return "Menlo";
        if (serif || lower.contains("serif") && !lower.contains("sans") || lower.contains("times") || lower.contains("roman")) return "Times New Roman";
        return "Helvetica Neue";
    }

    /** Glyphs on one baseline, split where a gap wider than a few spaces separates columns. */
    static List<Line> lines(List<Glyph> glyphs) {
        List<Glyph> sorted = new ArrayList<>(glyphs);
        sorted.sort(Comparator.comparingDouble(Glyph::y).thenComparingDouble(Glyph::x));
        List<List<Glyph>> rows = new ArrayList<>();
        for (Glyph g : sorted) {
            List<Glyph> row = rows.isEmpty() ? null : rows.get(rows.size() - 1);
            if (row != null && Math.abs(row.get(0).y() - g.y()) <= Math.max(1.5f, row.get(0).size() * 0.35f)) row.add(g);
            else rows.add(new ArrayList<>(List.of(g)));
        }
        List<Line> lines = new ArrayList<>();
        for (List<Glyph> row : rows) {
            row.sort(Comparator.comparingDouble(Glyph::x));
            List<Glyph> current = new ArrayList<>();
            for (Glyph g : row) {
                // About a letter's width apart: a new column (table cells, tab stops), not a word space.
                if (!current.isEmpty() && g.x() - current.get(current.size() - 1).right() > g.size() * 0.8f) {
                    lines.add(new Line(current));
                    current = new ArrayList<>();
                }
                current.add(g);
            }
            if (!current.isEmpty()) lines.add(new Line(current));
        }
        return lines;
    }

    /** Lines stacked at the same left edge, size and spacing share one text box, one paragraph each. */
    static List<List<Line>> blocks(List<Line> lines) {
        List<List<Line>> blocks = new ArrayList<>();
        List<Line> sorted = new ArrayList<>(lines);
        sorted.sort(Comparator.comparingDouble(Line::y).thenComparingDouble(Line::x));
        for (Line line : sorted) {
            List<Line> target = null;
            for (List<Line> block : blocks) {
                Line last = block.get(block.size() - 1);
                float gap = line.y() - last.y();
                if (Math.abs(line.x() - last.x()) < 2f && Math.abs(line.size() - last.size()) < last.size() * 0.15f
                        && gap > 0 && gap < last.size() * 1.8f) { target = block; break; }
            }
            if (target == null) blocks.add(new ArrayList<>(List.of(line))); else target.add(line);
        }
        return blocks;
    }

    static void addTextBox(XSLFSlide slide, List<Line> block, double fit, double left, double top) {
        float size = block.get(0).size();
        double x = block.stream().mapToDouble(Line::x).min().orElse(0);
        double right = block.stream().mapToDouble(Line::right).max().orElse(x + 10);
        // With exact spacing the first baseline sits about one font size below the box's top.
        double ascent = size, descent = size * 0.26;
        double y = block.get(0).y() - ascent, bottom = block.get(block.size() - 1).y() + descent;
        var box = slide.createTextBox();
        box.setAnchor(new Rectangle2D.Double(left + x * fit, top + y * fit, (right - x) * fit + size * fit * 0.5, (bottom - y) * fit));
        box.setInsets(new org.apache.poi.sl.usermodel.Insets2D(0, 0, 0, 0));
        box.setWordWrap(false);
        box.setVerticalAlignment(org.apache.poi.sl.usermodel.VerticalAlignment.TOP);
        box.clearText();
        for (int l = 0; l < block.size(); l++) {
            Line line = block.get(l);
            var paragraph = box.addNewTextParagraph();
            // Exact line spacing reproduces the PDF's baselines.
            double pitch = l == 0 ? line.size() * 1.2 : line.y() - block.get(l - 1).y();
            paragraph.setLineSpacing(-pitch * fit);
            paragraph.setSpaceBefore(0d);
            paragraph.setSpaceAfter(0d);
            Glyph previous = null;
            List<Glyph> span = new ArrayList<>();
            StringBuilder text = new StringBuilder();
            for (Glyph g : line.glyphs()) {
                boolean space = previous != null && g.x() - previous.right() > g.size() * 0.18f && !previous.text().endsWith(" ") && !g.text().startsWith(" ");
                if (!span.isEmpty()) {
                    Glyph style = span.get(0);
                    if (!g.font().equals(style.font()) || g.bold() != style.bold() || g.italic() != style.italic()
                            || g.color() != style.color() || Math.abs(g.size() - style.size()) > 0.5f) {
                        addRun(paragraph, text.toString(), span, fit);
                        text.setLength(0);
                        span.clear();
                    }
                }
                if (space) text.append(' ');
                text.append(g.text());
                span.add(g);
                previous = g;
            }
            addRun(paragraph, text.toString(), span, fit);
        }
    }

    static final java.awt.font.FontRenderContext METRICS = new java.awt.font.FontRenderContext(null, true, true);

    static void addRun(org.apache.poi.xslf.usermodel.XSLFTextParagraph paragraph, String text, List<Glyph> span, double fit) {
        if (text.isEmpty() || span.isEmpty()) return;
        Glyph style = span.get(0);
        var run = paragraph.addNewTextRun();
        run.setText(text);
        run.setFontFamily(style.font());
        // Whole points: Keynote and Quick Look drop the half point (11.5 renders as 11).
        double size = Math.max(1, Math.round(style.size() * fit));
        run.setFontSize(size);
        run.setBold(style.bold());
        run.setItalic(style.italic());
        run.setFontColor(new java.awt.Color(style.color()));
        // The slide font is rarely the PDF's exact font; spacing the letters to the PDF's width keeps the
        // text over its underlines, strikethroughs and table cells. (PowerPoint applies fractions of a
        // point; Keynote only whole points.)
        if (text.length() > 1) {
            var font = new java.awt.Font(style.font(), (style.bold() ? java.awt.Font.BOLD : 0) | (style.italic() ? java.awt.Font.ITALIC : 0), 1).deriveFont((float) size);
            double natural = font.getStringBounds(text, METRICS).getWidth();
            double wanted = (span.get(span.size() - 1).right() - span.get(0).x()) * fit;
            double spacing = (wanted - natural) / (text.length() - 1);
            if (Math.abs(spacing) > 0.01 && Math.abs(spacing) < size * 0.25) run.setCharacterSpacing(spacing);
        }
    }

    static float rotatedWidth(PDPage page, PDRectangle box) {
        return page.getRotation() % 180 == 0 ? box.getWidth() : box.getHeight();
    }

    static float rotatedHeight(PDPage page, PDRectangle box) {
        return page.getRotation() % 180 == 0 ? box.getHeight() : box.getWidth();
    }

    // MARK: - Spreadsheet model

    enum Kind { EMPTY, STRING, NUMBER, BOOLEAN, DATE, FORMULA_ONLY }

    static final class Cell {
        Kind kind = Kind.EMPTY;
        String text = "";
        double number;
        boolean bool;
        LocalDateTime date;
        String formula;     // Excel syntax without '=', kept when the target is XLSX
        String format;      // Excel number format, if any
        boolean bold;
        String display;     // formatted text, used for CSV/HTML

        String display() {
            if (display != null) return display;
            return switch (kind) {
                case EMPTY -> "";
                case STRING, FORMULA_ONLY -> text;
                case BOOLEAN -> bool ? "TRUE" : "FALSE";
                case NUMBER -> plainNumber(number);
                case DATE -> date.toLocalTime().equals(LocalTime.MIDNIGHT)
                        ? date.toLocalDate().toString()
                        : date.format(DateTimeFormatter.ISO_LOCAL_DATE_TIME);
            };
        }
    }

    static final class Sheet {
        final String name;
        final List<List<Cell>> rows = new ArrayList<>();
        final Map<Integer, Integer> columnWidths = new HashMap<>(); // POI units (1/256 char)
        final List<int[]> merges = new ArrayList<>();              // firstRow, lastRow, firstCol, lastCol

        Sheet(String name) { this.name = name; }

        void set(int row, int col, Cell cell) {
            while (rows.size() <= row) rows.add(new ArrayList<>());
            List<Cell> r = rows.get(row);
            while (r.size() <= col) r.add(new Cell());
            r.set(col, cell);
        }

        int columnCount() {
            int max = 0;
            for (List<Cell> r : rows) max = Math.max(max, r.size());
            return max;
        }

        /** Drops trailing empty rows and cells so repeated blank ODS/XLSX ranges don't bloat output. */
        void trim() {
            for (List<Cell> r : rows) while (!r.isEmpty() && r.get(r.size() - 1).kind == Kind.EMPTY) r.remove(r.size() - 1);
            while (!rows.isEmpty() && rows.get(rows.size() - 1).isEmpty()) rows.remove(rows.size() - 1);
        }
    }

    static String plainNumber(double value) {
        if (value == Math.rint(value) && Math.abs(value) < 1e15) return Long.toString((long) value);
        DecimalFormat format = new DecimalFormat("0.###############", DecimalFormatSymbols.getInstance(Locale.ROOT));
        return format.format(value);
    }

    static String extension(Path path) {
        String name = path.getFileName().toString().toLowerCase(Locale.ROOT);
        int dot = name.lastIndexOf('.');
        return dot < 0 ? "" : name.substring(dot + 1);
    }

    static String stripExtension(String name) {
        int dot = name.lastIndexOf('.');
        return dot <= 0 ? name : name.substring(0, dot);
    }

    static List<Sheet> readSheets(Path in) throws Exception {
        if (Files.size(in) > 128L * 1024 * 1024) throw new UserError("The spreadsheet is empty or exceeds the 128 MB conversion limit.");
        List<Sheet> sheets = switch (extension(in)) {
            case "csv" -> List.of(readDelimited(in, ','));
            case "tsv", "tab" -> List.of(readDelimited(in, '\t'));
            case "ods" -> readOds(in);
            default -> readWorkbook(in);
        };
        progress(0.5);
        for (Sheet s : sheets) s.trim();
        if (sheets.stream().allMatch(s -> s.rows.isEmpty())) throw new UserError("The spreadsheet is empty or exceeds the 128 MB conversion limit.");
        return sheets;
    }

    // MARK: Excel (XLS / XLSX) via POI

    static List<Sheet> readWorkbook(Path in) throws Exception {
        List<Sheet> result = new ArrayList<>();
        DataFormatter formatter = new DataFormatter(Locale.US);
        try (Workbook book = WorkbookFactory.create(in.toFile(), null, true)) {
            for (int s = 0; s < book.getNumberOfSheets(); s++) {
                org.apache.poi.ss.usermodel.Sheet source = book.getSheetAt(s);
                Sheet sheet = new Sheet(book.getSheetName(s));
                int maxColumn = 0;
                for (Row row : source) {
                    for (org.apache.poi.ss.usermodel.Cell c : row) {
                        Cell cell = convert(c, formatter, book);
                        if (cell.kind != Kind.EMPTY) {
                            sheet.set(row.getRowNum(), c.getColumnIndex(), cell);
                            maxColumn = Math.max(maxColumn, c.getColumnIndex());
                        }
                    }
                }
                for (int col = 0; col <= maxColumn; col++) {
                    int width = source.getColumnWidth(col);
                    if (width != source.getDefaultColumnWidth() * 256) sheet.columnWidths.put(col, width);
                }
                for (CellRangeAddress range : source.getMergedRegions()) {
                    sheet.merges.add(new int[]{range.getFirstRow(), range.getLastRow(), range.getFirstColumn(), range.getLastColumn()});
                }
                result.add(sheet);
            }
        } catch (org.apache.poi.EncryptedDocumentException e) {
            throw new UserError("Password-protected spreadsheets are not supported.");
        }
        return result;
    }

    static Cell convert(org.apache.poi.ss.usermodel.Cell c, DataFormatter formatter, Workbook book) {
        Cell cell = new Cell();
        CellType type = c.getCellType();
        if (type == CellType.FORMULA) {
            cell.formula = c.getCellFormula();
            type = c.getCachedFormulaResultType();
        }
        CellStyle style = c.getCellStyle();
        if (style != null) {
            org.apache.poi.ss.usermodel.Font font = book.getFontAt(style.getFontIndex());
            cell.bold = font != null && font.getBold();
            String format = style.getDataFormatString();
            if (format != null && !format.equals("General")) cell.format = format;
        }
        switch (type) {
            case STRING -> {
                cell.kind = Kind.STRING;
                cell.text = c.getStringCellValue();
            }
            case NUMERIC -> {
                if (DateUtil.isCellDateFormatted(c)) {
                    cell.kind = Kind.DATE;
                    cell.date = c.getLocalDateTimeCellValue();
                } else {
                    cell.kind = Kind.NUMBER;
                    cell.number = c.getNumericCellValue();
                }
            }
            case BOOLEAN -> {
                cell.kind = Kind.BOOLEAN;
                cell.bool = c.getBooleanCellValue();
            }
            case ERROR -> {
                cell.kind = Kind.STRING;
                cell.text = formatter.formatCellValue(c);
            }
            default -> {
                if (cell.formula != null) cell.kind = Kind.FORMULA_ONLY;
            }
        }
        if (cell.kind == Kind.NUMBER || cell.kind == Kind.DATE) {
            try {
                cell.display = formatter.formatRawCellContents(c.getNumericCellValue(), style.getDataFormat(), style.getDataFormatString());
            } catch (RuntimeException ignored) {
                // Unusual custom formats fall back to the plain value.
            }
        }
        return cell;
    }

    static void writeXlsx(List<Sheet> sheets, Path out) throws IOException {
        try (SXSSFWorkbook book = new SXSSFWorkbook(200)) {
            Map<String, CellStyle> styles = new HashMap<>();
            DataFormat formats = book.createDataFormat();
            org.apache.poi.ss.usermodel.Font boldFont = book.createFont();
            boldFont.setBold(true);
            Set<String> used = new HashSet<>();
            for (Sheet sheet : sheets) {
                String name = uniqueSheetName(WorkbookUtil.createSafeSheetName(sheet.name.isBlank() ? "Sheet" : sheet.name), used);
                org.apache.poi.ss.usermodel.Sheet target = book.createSheet(name);
                sheet.columnWidths.forEach((col, width) -> target.setColumnWidth(col, Math.min(width, 255 * 256)));
                for (int r = 0; r < sheet.rows.size(); r++) {
                    List<Cell> cells = sheet.rows.get(r);
                    if (cells.isEmpty()) continue;
                    Row row = target.createRow(r);
                    for (int col = 0; col < cells.size(); col++) {
                        Cell cell = cells.get(col);
                        if (cell.kind == Kind.EMPTY) continue;
                        org.apache.poi.ss.usermodel.Cell c = row.createCell(col);
                        String format = cell.kind == Kind.DATE && cell.format == null
                                ? (cell.date.toLocalTime().equals(LocalTime.MIDNIGHT) ? "yyyy-mm-dd" : "yyyy-mm-dd hh:mm:ss")
                                : cell.format;
                        String key = format + "|" + cell.bold;
                        if (format != null || cell.bold) {
                            CellStyle style = styles.computeIfAbsent(key, k -> {
                                CellStyle s = book.createCellStyle();
                                if (format != null) s.setDataFormat(formats.getFormat(format));
                                if (cell.bold) s.setFont(boldFont);
                                return s;
                            });
                            c.setCellStyle(style);
                        }
                        if (cell.formula != null) {
                            try {
                                c.setCellFormula(cell.formula);
                                continue;
                            } catch (RuntimeException ignored) {
                                // Formulas POI cannot parse keep their cached value instead.
                            }
                        }
                        switch (cell.kind) {
                            case STRING, FORMULA_ONLY -> c.setCellValue(cell.text);
                            case NUMBER -> c.setCellValue(cell.number);
                            case BOOLEAN -> c.setCellValue(cell.bool);
                            case DATE -> c.setCellValue(cell.date);
                            default -> { }
                        }
                    }
                }
                for (int[] m : sheet.merges) {
                    if (m[0] != m[1] || m[2] != m[3]) target.addMergedRegion(new CellRangeAddress(m[0], m[1], m[2], m[3]));
                }
            }
            try (OutputStream stream = Files.newOutputStream(out)) {
                book.write(stream);
            }
            book.dispose();
        }
    }

    static String uniqueSheetName(String name, Set<String> used) {
        String candidate = name;
        for (int i = 2; !used.add(candidate.toLowerCase(Locale.ROOT)); i++) {
            String suffix = " " + i;
            candidate = name.substring(0, Math.min(name.length(), 31 - suffix.length())) + suffix;
        }
        return candidate;
    }

    // MARK: CSV / TSV

    static Sheet readDelimited(Path in, char delimiter) throws IOException {
        byte[] bytes = Files.readAllBytes(in);
        String text = decode(bytes);
        Sheet sheet = new Sheet(stripExtension(in.getFileName().toString()));
        int row = 0, col = 0;
        StringBuilder field = new StringBuilder();
        boolean quoted = false, wasQuoted = false;
        for (int i = 0; i < text.length(); i++) {
            char ch = text.charAt(i);
            if (quoted) {
                if (ch == '"') {
                    if (i + 1 < text.length() && text.charAt(i + 1) == '"') {
                        field.append('"');
                        i++;
                    } else {
                        quoted = false;
                    }
                } else {
                    field.append(ch);
                }
            } else if (ch == '"' && field.length() == 0) {
                quoted = true;
                wasQuoted = true;
            } else if (ch == delimiter) {
                sheet.set(row, col++, typed(field.toString(), wasQuoted));
                field.setLength(0);
                wasQuoted = false;
            } else if (ch == '\n' || ch == '\r') {
                if (ch == '\r' && i + 1 < text.length() && text.charAt(i + 1) == '\n') i++;
                sheet.set(row, col, typed(field.toString(), wasQuoted));
                field.setLength(0);
                wasQuoted = false;
                row++;
                col = 0;
            } else {
                field.append(ch);
            }
        }
        if (field.length() > 0 || col > 0 || wasQuoted) sheet.set(row, col, typed(field.toString(), wasQuoted));
        return sheet;
    }

    static String decode(byte[] bytes) {
        int start = bytes.length >= 3 && (bytes[0] & 0xff) == 0xEF && (bytes[1] & 0xff) == 0xBB && (bytes[2] & 0xff) == 0xBF ? 3 : 0;
        if (bytes.length >= 2 && (bytes[0] & 0xff) == 0xFF && (bytes[1] & 0xff) == 0xFE) return new String(bytes, 2, bytes.length - 2, StandardCharsets.UTF_16LE);
        if (bytes.length >= 2 && (bytes[0] & 0xff) == 0xFE && (bytes[1] & 0xff) == 0xFF) return new String(bytes, 2, bytes.length - 2, StandardCharsets.UTF_16BE);
        try {
            return StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .decode(java.nio.ByteBuffer.wrap(bytes, start, bytes.length - start)).toString();
        } catch (CharacterCodingException e) {
            return new String(bytes, Charset.forName("windows-1252"));
        }
    }

    /** Numbers stay numbers so spreadsheet targets can calculate with them; quoted fields stay text. */
    static Cell typed(String value, boolean quoted) {
        Cell cell = new Cell();
        if (value.isEmpty()) return cell;
        cell.kind = Kind.STRING;
        cell.text = value;
        if (quoted) return cell;
        String trimmed = value.trim();
        if (trimmed.matches("[-+]?(\\d+\\.?\\d*|\\.\\d+)([eE][-+]?\\d+)?") && !(trimmed.length() > 1 && trimmed.startsWith("0") && !trimmed.startsWith("0."))) {
            try {
                cell.number = Double.parseDouble(trimmed);
                cell.kind = Kind.NUMBER;
                cell.display = value;
            } catch (NumberFormatException ignored) {
                // stays text
            }
        } else if (trimmed.equalsIgnoreCase("true") || trimmed.equalsIgnoreCase("false")) {
            cell.kind = Kind.BOOLEAN;
            cell.bool = trimmed.equalsIgnoreCase("true");
        }
        return cell;
    }

    static void writeDelimited(Sheet sheet, Path out, char delimiter) throws IOException {
        try (Writer writer = Files.newBufferedWriter(out, StandardCharsets.UTF_8)) {
            for (List<Cell> row : sheet.rows) {
                for (int col = 0; col < row.size(); col++) {
                    if (col > 0) writer.write(delimiter);
                    String value = row.get(col).display();
                    if (delimiter == '\t') {
                        writer.write(value.replace('\t', ' ').replace("\r\n", " ").replace('\n', ' ').replace('\r', ' '));
                    } else if (value.indexOf(delimiter) >= 0 || value.indexOf('"') >= 0 || value.indexOf('\n') >= 0 || value.indexOf('\r') >= 0
                            || (!value.isEmpty() && (Character.isWhitespace(value.charAt(0)) || Character.isWhitespace(value.charAt(value.length() - 1))))) {
                        writer.write('"');
                        writer.write(value.replace("\"", "\"\""));
                        writer.write('"');
                    } else {
                        writer.write(value);
                    }
                }
                writer.write("\r\n");
            }
        }
    }

    // MARK: OpenDocument spreadsheet

    static final String TABLE = "urn:oasis:names:tc:opendocument:xmlns:table:1.0";
    static final String OFFICE = "urn:oasis:names:tc:opendocument:xmlns:office:1.0";
    static final String TEXT = "urn:oasis:names:tc:opendocument:xmlns:text:1.0";

    static List<Sheet> readOds(Path in) throws Exception {
        try (ZipFile zip = new ZipFile(in.toFile())) {
            ZipEntry entry = zip.getEntry("content.xml");
            if (entry == null) throw new UserError("This file is not a readable ODS spreadsheet.");
            if (entry.getSize() > 256L * 1024 * 1024) throw new UserError("The spreadsheet is empty or exceeds the 128 MB conversion limit.");
            DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
            factory.setNamespaceAware(true);
            factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
            factory.setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true);
            factory.setExpandEntityReferences(false);
            DocumentBuilder builder = factory.newDocumentBuilder();
            org.w3c.dom.Document doc;
            try (InputStream stream = zip.getInputStream(entry)) {
                doc = builder.parse(stream);
            }
            List<Sheet> sheets = new ArrayList<>();
            NodeList tables = doc.getElementsByTagNameNS(TABLE, "table");
            for (int t = 0; t < tables.getLength(); t++) {
                Element table = (Element) tables.item(t);
                Sheet sheet = new Sheet(table.getAttributeNS(TABLE, "name"));
                int[] row = {0};
                readOdsRows(table, sheet, row);
                sheets.add(sheet);
            }
            return sheets;
        }
    }

    static void readOdsRows(Element parent, Sheet sheet, int[] row) {
        for (Node node = parent.getFirstChild(); node != null; node = node.getNextSibling()) {
            if (!(node instanceof Element element) || !TABLE.equals(element.getNamespaceURI())) continue;
            switch (element.getLocalName()) {
                case "table-row" -> {
                    int repeat = repeatCount(element, "number-rows-repeated");
                    boolean empty = isEmptyOdsRow(element);
                    if (empty) {
                        row[0] += Math.min(repeat, 1_048_576);
                        continue;
                    }
                    for (int i = 0; i < Math.min(repeat, 10_000); i++) readOdsRow(element, sheet, row[0]++);
                }
                case "table-row-group", "table-header-rows", "table-rows" -> readOdsRows(element, sheet, row);
                default -> { }
            }
        }
    }

    static boolean isEmptyOdsRow(Element row) {
        for (Node node = row.getFirstChild(); node != null; node = node.getNextSibling()) {
            if (node instanceof Element cell && (cell.hasAttributeNS(OFFICE, "value-type") || !cell.getTextContent().isEmpty())) return false;
        }
        return true;
    }

    static void readOdsRow(Element rowElement, Sheet sheet, int row) {
        int col = 0;
        for (Node node = rowElement.getFirstChild(); node != null; node = node.getNextSibling()) {
            if (!(node instanceof Element element) || !TABLE.equals(element.getNamespaceURI())) continue;
            if (!element.getLocalName().equals("table-cell") && !element.getLocalName().equals("covered-table-cell")) continue;
            int repeat = repeatCount(element, "number-columns-repeated");
            Cell cell = odsCell(element);
            if (cell.kind == Kind.EMPTY) {
                col += repeat;
                continue;
            }
            for (int i = 0; i < Math.min(repeat, 1024); i++) sheet.set(row, col++, cell);
            int spanRows = repeatCount(element, "number-rows-spanned"), spanCols = repeatCount(element, "number-columns-spanned");
            if (spanRows > 1 || spanCols > 1) sheet.merges.add(new int[]{row, row + spanRows - 1, col - 1, col - 1 + spanCols - 1});
        }
    }

    static int repeatCount(Element element, String attribute) {
        String value = element.getAttributeNS(TABLE, attribute);
        if (value.isEmpty()) return 1;
        try {
            return Math.max(1, Integer.parseInt(value));
        } catch (NumberFormatException e) {
            return 1;
        }
    }

    static Cell odsCell(Element element) {
        Cell cell = new Cell();
        StringBuilder text = new StringBuilder();
        NodeList paragraphs = element.getElementsByTagNameNS(TEXT, "p");
        for (int i = 0; i < paragraphs.getLength(); i++) {
            if (i > 0) text.append('\n');
            text.append(paragraphs.item(i).getTextContent());
        }
        String type = element.getAttributeNS(OFFICE, "value-type");
        cell.text = text.toString();
        cell.display = cell.text.isEmpty() ? null : cell.text;
        try {
            switch (type) {
                case "float", "percentage", "currency" -> {
                    cell.kind = Kind.NUMBER;
                    cell.number = Double.parseDouble(element.getAttributeNS(OFFICE, "value"));
                    if (type.equals("percentage")) cell.format = "0.00%";
                }
                case "date" -> {
                    String value = element.getAttributeNS(OFFICE, "date-value");
                    cell.kind = Kind.DATE;
                    cell.date = value.contains("T") ? LocalDateTime.parse(value.length() > 19 ? value.substring(0, 19) : value) : LocalDate.parse(value).atStartOfDay();
                }
                case "time" -> {
                    cell.kind = Kind.STRING;
                }
                case "boolean" -> {
                    cell.kind = Kind.BOOLEAN;
                    cell.bool = Boolean.parseBoolean(element.getAttributeNS(OFFICE, "boolean-value"));
                }
                default -> cell.kind = cell.text.isEmpty() ? Kind.EMPTY : Kind.STRING;
            }
        } catch (RuntimeException e) {
            cell.kind = cell.text.isEmpty() ? Kind.EMPTY : Kind.STRING;
        }
        return cell;
    }

    static void writeOds(List<Sheet> sheets, Path out) throws IOException {
        StringBuilder content = new StringBuilder(1 << 16);
        content.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
                .append("<office:document-content xmlns:office=\"").append(OFFICE).append("\" xmlns:table=\"").append(TABLE)
                .append("\" xmlns:text=\"").append(TEXT)
                .append("\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\"")
                .append(" xmlns:number=\"urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0\" office:version=\"1.3\">")
                .append("<office:automatic-styles>")
                .append("<number:date-style style:name=\"N1\"><number:year number:style=\"long\"/><number:text>-</number:text><number:month number:style=\"long\"/><number:text>-</number:text><number:day number:style=\"long\"/></number:date-style>")
                .append("<style:style style:name=\"date\" style:family=\"table-cell\" style:data-style-name=\"N1\"/>")
                .append("<style:style style:name=\"bold\" style:family=\"table-cell\"><style:text-properties fo:font-weight=\"bold\"/></style:style>")
                .append("</office:automatic-styles><office:body><office:spreadsheet>");
        Set<String> used = new HashSet<>();
        for (Sheet sheet : sheets) {
            String name = uniqueSheetName(sheet.name.isBlank() ? "Sheet" : sheet.name.replaceAll("[\\[\\]*?:/\\\\]", "_"), used);
            content.append("<table:table table:name=\"").append(xml(name)).append("\">");
            int columns = Math.max(1, sheet.columnCount());
            content.append("<table:table-column table:number-columns-repeated=\"").append(columns).append("\"/>");
            for (List<Cell> row : sheet.rows) {
                content.append("<table:table-row>");
                for (Cell cell : row) appendOdsCell(content, cell);
                if (row.isEmpty()) content.append("<table:table-cell/>");
                content.append("</table:table-row>");
            }
            if (sheet.rows.isEmpty()) content.append("<table:table-row><table:table-cell/></table:table-row>");
            content.append("</table:table>");
        }
        content.append("</office:spreadsheet></office:body></office:document-content>");

        String manifest = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.3\">"
                + "<manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.spreadsheet\"/>"
                + "<manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/>"
                + "<manifest:file-entry manifest:full-path=\"meta.xml\" manifest:media-type=\"text/xml\"/>"
                + "</manifest:manifest>";
        String meta = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-meta xmlns:office=\"" + OFFICE
                + "\" xmlns:meta=\"urn:oasis:names:tc:opendocument:xmlns:meta:1.0\" office:version=\"1.3\"><office:meta><meta:generator>WheelConvert</meta:generator></office:meta></office:document-meta>";

        try (ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(out))) {
            byte[] mime = "application/vnd.oasis.opendocument.spreadsheet".getBytes(StandardCharsets.US_ASCII);
            ZipEntry mimeEntry = new ZipEntry("mimetype");
            mimeEntry.setMethod(ZipEntry.STORED);
            mimeEntry.setSize(mime.length);
            CRC32 crc = new CRC32();
            crc.update(mime);
            mimeEntry.setCrc(crc.getValue());
            zip.putNextEntry(mimeEntry);
            zip.write(mime);
            zip.closeEntry();
            putEntry(zip, "content.xml", content.toString());
            putEntry(zip, "meta.xml", meta);
            putEntry(zip, "META-INF/manifest.xml", manifest);
        }
    }

    static void appendOdsCell(StringBuilder out, Cell cell) {
        String style = cell.bold ? " table:style-name=\"bold\"" : "";
        switch (cell.kind) {
            case EMPTY -> out.append("<table:table-cell/>");
            case NUMBER -> out.append("<table:table-cell").append(style).append(" office:value-type=\"float\" office:value=\"")
                    .append(plainNumber(cell.number)).append("\"><text:p>").append(xml(cell.display())).append("</text:p></table:table-cell>");
            case BOOLEAN -> out.append("<table:table-cell").append(style).append(" office:value-type=\"boolean\" office:boolean-value=\"")
                    .append(cell.bool).append("\"><text:p>").append(cell.bool ? "TRUE" : "FALSE").append("</text:p></table:table-cell>");
            case DATE -> out.append("<table:table-cell table:style-name=\"date\" office:value-type=\"date\" office:date-value=\"")
                    .append(cell.date.toLocalTime().equals(LocalTime.MIDNIGHT) ? cell.date.toLocalDate().toString() : cell.date.format(DateTimeFormatter.ISO_LOCAL_DATE_TIME))
                    .append("\"><text:p>").append(xml(cell.display())).append("</text:p></table:table-cell>");
            default -> {
                out.append("<table:table-cell").append(style).append(" office:value-type=\"string\">");
                for (String line : cell.display().split("\n", -1)) out.append("<text:p>").append(xml(line)).append("</text:p>");
                out.append("</table:table-cell>");
            }
        }
    }

    static void putEntry(ZipOutputStream zip, String name, String text) throws IOException {
        zip.putNextEntry(new ZipEntry(name));
        zip.write(text.getBytes(StandardCharsets.UTF_8));
        zip.closeEntry();
    }

    static String xml(String value) {
        StringBuilder out = new StringBuilder(value.length());
        for (int i = 0; i < value.length(); i++) {
            char ch = value.charAt(i);
            switch (ch) {
                case '&' -> out.append("&amp;");
                case '<' -> out.append("&lt;");
                case '>' -> out.append("&gt;");
                case '"' -> out.append("&quot;");
                default -> {
                    if (ch < 0x20 && ch != '\t' && ch != '\n' && ch != '\r') continue; // not allowed in XML 1.0
                    out.append(ch);
                }
            }
        }
        return out.toString();
    }

    // MARK: Writing

    /**
     * Writes the sheets in the output's format. CSV and TSV hold one table, so a workbook with
     * several non-empty sheets becomes one file per sheet beside the requested output.
     */
    static void writeSheets(List<Sheet> sheets, Path out) throws Exception {
        String ext = extension(out);
        switch (ext) {
            case "xlsx" -> {
                writeXlsx(sheets, out);
                emit(out);
            }
            case "ods" -> {
                writeOds(sheets, out);
                emit(out);
            }
            case "csv", "tsv" -> {
                char delimiter = ext.equals("csv") ? ',' : '\t';
                List<Sheet> nonEmpty = sheets.stream().filter(s -> !s.rows.isEmpty()).toList();
                if (nonEmpty.size() <= 1) {
                    writeDelimited(nonEmpty.isEmpty() ? sheets.get(0) : nonEmpty.get(0), out, delimiter);
                    emit(out);
                } else {
                    String base = stripExtension(out.getFileName().toString());
                    Set<String> used = new HashSet<>();
                    for (Sheet sheet : nonEmpty) {
                        String safe = sheet.name.replaceAll("[/:\\\\]", "-").trim();
                        String name = uniqueSheetName(base + " - " + (safe.isEmpty() ? "Sheet" : safe), used);
                        Path file = out.resolveSibling(name + "." + ext);
                        for (int i = 2; Files.exists(file); i++) file = out.resolveSibling(name + " " + i + "." + ext);
                        writeDelimited(sheet, file, delimiter);
                        emit(file);
                    }
                }
            }
            default -> throw new UserError("Unsupported spreadsheet output ." + ext);
        }
        progress(1);
    }

    /** HTML that WheelConvert prints to PDF: one section per sheet, each on its own page. */
    static void writeHtml(List<Sheet> sheets, Path out, String title) throws IOException {
        StringBuilder html = new StringBuilder(1 << 16);
        html.append("<!doctype html><html><head><meta charset=\"utf-8\"><title>").append(xml(title)).append("</title><style>")
                .append("@page{margin:36pt}body{font:9pt -apple-system,Helvetica,Arial,sans-serif;margin:0;color:#000}")
                .append("h1{font-size:11pt;margin:0 0 8pt}section{break-after:page}section:last-child{break-after:auto}")
                .append("table{border-collapse:collapse}td{border:0.5pt solid #b8b8b8;padding:2pt 4pt;vertical-align:top;white-space:pre-wrap;max-width:240pt;overflow-wrap:anywhere}")
                .append("td.n{text-align:right;white-space:nowrap}td.b{font-weight:bold}tr{break-inside:avoid}")
                .append("</style></head><body>");
        boolean multiple = sheets.stream().filter(s -> !s.rows.isEmpty()).count() > 1;
        for (Sheet sheet : sheets) {
            if (sheet.rows.isEmpty()) continue;
            html.append("<section>");
            if (multiple) html.append("<h1>").append(xml(sheet.name)).append("</h1>");
            html.append("<table>");
            int columns = sheet.columnCount();
            Set<Long> covered = new HashSet<>();
            Map<Long, int[]> spans = new HashMap<>();
            for (int[] m : sheet.merges) {
                spans.put(((long) m[0] << 32) | m[2], new int[]{m[1] - m[0] + 1, m[3] - m[2] + 1});
                for (int r = m[0]; r <= m[1]; r++) for (int c = m[2]; c <= m[3]; c++) if (r != m[0] || c != m[2]) covered.add(((long) r << 32) | c);
            }
            for (int r = 0; r < sheet.rows.size(); r++) {
                List<Cell> row = sheet.rows.get(r);
                html.append("<tr>");
                for (int c = 0; c < columns; c++) {
                    long key = ((long) r << 32) | c;
                    if (covered.contains(key)) continue;
                    Cell cell = c < row.size() ? row.get(c) : new Cell();
                    String cls = (cell.kind == Kind.NUMBER || cell.kind == Kind.DATE ? "n" : "") + (cell.bold ? " b" : "");
                    html.append("<td");
                    if (!cls.isBlank()) html.append(" class=\"").append(cls.trim()).append('"');
                    int[] span = spans.get(key);
                    if (span != null) html.append(" rowspan=\"").append(span[0]).append("\" colspan=\"").append(span[1]).append('"');
                    html.append('>').append(xml(cell.display())).append("</td>");
                }
                html.append("</tr>");
            }
            html.append("</table></section>");
        }
        int widest = 0;
        for (Sheet sheet : sheets) widest = Math.max(widest, sheet.columnCount());
        html.append("<!--columns:").append(widest).append("-->");
        html.append("</body></html>");
        Files.writeString(out, html.toString(), StandardCharsets.UTF_8);
        emit(out);
        progress(1);
    }

    // MARK: - PDF tables

    /** Rebuilds each PDF page as a sheet: text lines become rows, aligned text runs become columns. */
    static List<Sheet> readPdfTables(Path in) throws Exception {
        List<Sheet> sheets = new ArrayList<>();
        try (PDDocument pdf = Loader.loadPDF(in.toFile())) {
            int count = pdf.getNumberOfPages();
            if (count == 0) throw new UserError("This PDF has no pages.");
            if (!pdf.getCurrentAccessPermission().canExtractContent()) throw new UserError("This PDF does not allow copying its content.");
            boolean anyText = false;
            for (int p = 1; p <= count; p++) {
                PositionStripper stripper = new PositionStripper();
                stripper.setStartPage(p);
                stripper.setEndPage(p);
                stripper.getText(pdf);
                Sheet sheet = layout(stripper.runs, "Page " + p);
                anyText |= !sheet.rows.isEmpty();
                sheets.add(sheet);
                progress(0.9 * p / count);
            }
            if (!anyText) throw new UserError("This PDF has no selectable text. Scanned pages need OCR before text can be exported.");
        } catch (org.apache.pdfbox.pdmodel.encryption.InvalidPasswordException e) {
            throw new UserError("The PDF cannot be read or is password-protected.");
        }
        return sheets;
    }

    record Run(String text, float x, float right, float y, float height, boolean bold) { }

    static final class PositionStripper extends PDFTextStripper {
        final List<Run> runs = new ArrayList<>();

        PositionStripper() throws IOException {
            setSortByPosition(true);
            setSuppressDuplicateOverlappingText(true);
        }

        @Override
        protected void writeString(String text, List<TextPosition> positions) {
            // Split each line fragment where the gap between glyphs is wider than a couple of spaces.
            StringBuilder current = new StringBuilder();
            TextPosition start = null, last = null;
            for (TextPosition position : positions) {
                if (last != null) {
                    float gap = position.getXDirAdj() - (last.getXDirAdj() + last.getWidthDirAdj());
                    float space = Math.max(position.getWidthOfSpace(), position.getFontSizeInPt() * 0.25f);
                    if (gap > space * 2.2f || Math.abs(position.getYDirAdj() - last.getYDirAdj()) > position.getHeightDir()) {
                        add(current, start, last);
                        current.setLength(0);
                        start = null;
                    }
                }
                if (start == null) start = position;
                current.append(position.getUnicode());
                last = position;
            }
            add(current, start, last);
        }

        void add(StringBuilder text, TextPosition start, TextPosition end) {
            String value = text.toString().strip();
            if (value.isEmpty() || start == null) return;
            String font = start.getFont() == null || start.getFont().getName() == null ? "" : start.getFont().getName().toLowerCase(Locale.ROOT);
            runs.add(new Run(value, start.getXDirAdj(), end.getXDirAdj() + end.getWidthDirAdj(), start.getYDirAdj(),
                    Math.max(1f, start.getHeightDir()), font.contains("bold") || font.contains("black") || font.contains("heavy")));
        }
    }

    static Sheet layout(List<Run> runs, String name) {
        Sheet sheet = new Sheet(name);
        if (runs.isEmpty()) return sheet;
        List<Run> sorted = new ArrayList<>(runs);
        sorted.sort(Comparator.comparingDouble(Run::y).thenComparingDouble(Run::x));
        // Lines: runs whose baselines are within half a line height.
        List<List<Run>> lines = new ArrayList<>();
        for (Run run : sorted) {
            List<Run> line = lines.isEmpty() ? null : lines.get(lines.size() - 1);
            if (line != null && Math.abs(line.get(0).y() - run.y()) <= Math.max(2f, line.get(0).height() * 0.5f)) line.add(run);
            else lines.add(new ArrayList<>(List.of(run)));
        }
        // Columns: cluster run left edges across the page.
        List<Float> starts = new ArrayList<>();
        for (List<Run> line : lines) for (Run run : line) starts.add(run.x());
        Collections.sort(starts);
        List<Float> columns = new ArrayList<>();
        for (float x : starts) {
            if (columns.isEmpty() || x - columns.get(columns.size() - 1) > 12f) columns.add(x);
        }
        for (int r = 0; r < lines.size(); r++) {
            List<Run> line = lines.get(r);
            line.sort(Comparator.comparingDouble(Run::x));
            int lastColumn = -1;
            for (Run run : line) {
                int column = 0;
                for (int c = 0; c < columns.size(); c++) if (columns.get(c) <= run.x() + 0.5f) column = c;
                column = Math.max(column, lastColumn + 1);
                lastColumn = column;
                Cell cell = number(run.text());
                cell.bold = run.bold();
                sheet.set(r, column, cell);
            }
        }
        return sheet;
    }

    /** Reads "1,234.50", "(12)", "45%" and "$9.99" as numbers; everything else stays text. */
    static Cell number(String text) {
        Cell cell = new Cell();
        cell.kind = Kind.STRING;
        cell.text = text;
        String value = text.replace("−", "-").trim();
        boolean negative = value.startsWith("(") && value.endsWith(")");
        if (negative) value = value.substring(1, value.length() - 1);
        boolean percent = value.endsWith("%");
        if (percent) value = value.substring(0, value.length() - 1);
        value = value.replaceFirst("^[$€£¥]", "").replace(",", "");
        if (value.matches("[-+]?\\d+(\\.\\d+)?") && !(value.length() > 1 && value.startsWith("0") && !value.startsWith("0."))) {
            double number = Double.parseDouble(value) * (negative ? -1 : 1);
            cell.kind = Kind.NUMBER;
            cell.number = percent ? number / 100 : number;
            cell.display = text;
            if (percent) cell.format = "0.##%";
        }
        return cell;
    }
}
