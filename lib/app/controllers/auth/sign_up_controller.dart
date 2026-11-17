
import 'dart:io';

import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';

class RegisterController extends GetxController {
  bool _isLoading = false;
  String message = '';
  final box = GetStorage();

  bool get isLoading => _isLoading;

  final GetConnect _connect = GetConnect();

  Future<void> simulateSignUp(
    String fullName,
    String email,
    String phoneNumber,
    String password,
    Function(String message) showSuccessMessage,
    Function(String message) showErrorMessage,
    Function() navigateToNextPage,
  ) async {
    final url =
        'https://payboss-be.pidagt.easypanel.host/user/auth/signup';

    final requestBody = {
      "fullName": fullName,
      "email": email,
      "phoneNumber": phoneNumber,
      "password": password,
    };

    final headers = {'Content-Type': 'application/json'};

    int retryCount = 0;
    const maxRetries = 3;
    int delay = 1; // Initial delay in seconds

    while (retryCount < maxRetries) {
      try {
        _isLoading = true;
        update();

        // Make the HTTP request using GetConnect
        final response = await _connect.post(
          url,
          requestBody,
          headers: headers,
        );

        if (response.statusCode == 200 || response.statusCode == 201) {
          final responseData = response.body;
          print('$responseData');

          // Save user data to Hive
          await box.write('name', responseData['data']['user']['fullName']);
          await box.write('email', responseData['data']['user']['email']);
          await box.write(
              'phoneNumber', responseData['data']['user']['phoneNumber']);
          await box.write(
              'referralCode', responseData['data']['user']['referralCode']);

          // Show success message and navigate
          showSuccessMessage('${responseData['message']}');
          navigateToNextPage();
          return;
        } else if (response.statusCode! >= 500) {
          // Server error (retry)
          retryCount++;
          await Future.delayed(Duration(seconds: delay));
          delay *= 2; // Exponential backoff
          continue;
        } else {
          // Client error (no retry)
          final responseData = response.body;
          showErrorMessage('${responseData['message']}');
          print('${responseData['message']}');
          break;
        }
      } on SocketException catch (e) {
        if (retryCount < maxRetries) {
          retryCount++;
          await Future.delayed(Duration(seconds: delay));
          delay *= 2; // Increase delay for next attempt
        } else {
          showErrorMessage('No internet connection: ${e.message}');
          break;
        }
      } catch (e) {
        showErrorMessage('An unexpected error occurred: $e');
        break;
      } finally {
        _isLoading = false;
        update();
      }
    }
  }
}
