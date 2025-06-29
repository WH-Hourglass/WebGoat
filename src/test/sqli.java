import java.sql.*;
import javax.servlet.http.*;

public class LoginServlet extends HttpServlet {

    protected void doPost(HttpServletRequest request, HttpServletResponse response) {
        String username = request.getParameter("username");
        String password = request.getParameter("password");

        // ☠️ 취약점 1: 하드코딩된 DB 비밀번호
        String dbPassword = "iamawsexpert"; 

        try {
            // ☠️ 취약점 2: SQL Injection 가능
            String query = "SELECT * FROM users WHERE username = '" + username + "' AND password = '" + password + "'";

            // ☠️ 취약점 3: DB 연결정보 노출 + 암호화 미사용
            Connection conn = DriverManager.getConnection("jdbc:mysql://localhost:3306/appdb", "root", dbPassword);
            Statement stmt = conn.createStatement();
            ResultSet rs = stmt.executeQuery(query);

            if (rs.next()) {
                response.getWriter().println("Login success!");
            } else {
                response.getWriter().println("Login failed.");
            }

            conn.close();
        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}
