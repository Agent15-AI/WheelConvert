import org.apache.poi.hslf.usermodel.*;
import org.apache.poi.hssf.usermodel.HSSFWorkbook;
import org.apache.poi.ss.usermodel.*;
import org.apache.poi.xslf.usermodel.*;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import java.awt.*;
import java.awt.geom.Rectangle2D;
import java.io.*;
import java.time.LocalDate;

/** Writes Office test fixtures: java -cp "lib/*" GenOffice.java <outDir> */
public class GenOffice {
    public static void main(String[] a) throws Exception {
        File dir = new File(a[0]);
        try (XMLSlideShow ppt = new XMLSlideShow()) {
            for (int i = 1; i <= 3; i++) {
                XSLFSlide slide = ppt.createSlide();
                XSLFTextBox title = slide.createTextBox();
                title.setAnchor(new Rectangle2D.Double(40, 40, 640, 80));
                XSLFTextRun run = title.addNewTextParagraph().addNewTextRun();
                run.setText("Slide " + i + " title"); run.setFontSize(36.0); run.setBold(true);
                XSLFTextBox body = slide.createTextBox();
                body.setAnchor(new Rectangle2D.Double(40, 140, 640, 200));
                body.addNewTextParagraph().addNewTextRun().setText("Body text with unicode ✓ é ü");
                XSLFAutoShape shape = slide.createAutoShape();
                shape.setShapeType(org.apache.poi.sl.usermodel.ShapeType.ELLIPSE);
                shape.setAnchor(new Rectangle2D.Double(500, 300, 150, 100));
                shape.setFillColor(new java.awt.Color(90, 92, 255));
            }
            try (OutputStream out = new FileOutputStream(new File(dir, "sample.pptx"))) { ppt.write(out); }
        }
        try (HSLFSlideShow ppt = new HSLFSlideShow()) {
            HSLFSlide slide = ppt.createSlide();
            HSLFTextBox box = slide.createTextBox();
            box.setAnchor(new Rectangle2D.Double(40, 40, 600, 100));
            box.setText("Legacy PPT slide");
            try (OutputStream out = new FileOutputStream(new File(dir, "sample.ppt"))) { ppt.write(out); }
        }
        for (boolean xlsx : new boolean[]{true, false}) {
            try (Workbook book = xlsx ? new XSSFWorkbook() : new HSSFWorkbook()) {
                Sheet sheet = book.createSheet("Data");
                CellStyle bold = book.createCellStyle(); org.apache.poi.ss.usermodel.Font f = book.createFont(); f.setBold(true); bold.setFont(f);
                CellStyle date = book.createCellStyle(); date.setDataFormat(book.createDataFormat().getFormat("yyyy-mm-dd"));
                String[] head = {"Item", "Qty", "Price", "Total", "Date"};
                Row h = sheet.createRow(0);
                for (int c = 0; c < head.length; c++) { org.apache.poi.ss.usermodel.Cell cell = h.createCell(c); cell.setCellValue(head[c]); cell.setCellStyle(bold); }
                for (int r = 1; r <= 4; r++) {
                    Row row = sheet.createRow(r);
                    row.createCell(0).setCellValue("Item " + r);
                    row.createCell(1).setCellValue(r * 2);
                    row.createCell(2).setCellValue(r * 1.25);
                    row.createCell(3).setCellFormula("B" + (r + 1) + "*C" + (r + 1));
                    org.apache.poi.ss.usermodel.Cell d = row.createCell(4); d.setCellValue(LocalDate.of(2026, 1, r)); d.setCellStyle(date);
                }
                book.getCreationHelper().createFormulaEvaluator().evaluateAll();
                Sheet second = book.createSheet("Notes");
                second.createRow(0).createCell(0).setCellValue("Second sheet");
                try (OutputStream out = new FileOutputStream(new File(dir, xlsx ? "sample.xlsx" : "sample.xls"))) { book.write(out); }
            }
        }
    }
}
